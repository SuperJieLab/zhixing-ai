import 'dart:convert';

import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;

import 'package:zhixing_ai/core/data/repository/settings_repository.dart';
import 'package:zhixing_ai/core/llm/cloud_completion.dart';
import 'package:zhixing_ai/core/llm/inference.dart';
import 'package:zhixing_ai/core/llm/llama_service.dart';
import 'package:zhixing_ai/core/llm/llm.dart';
import 'package:zhixing_ai/core/llm/think_tag_stripper.dart';
import 'package:zhixing_ai/core/logger.dart';

/// 单次补全的函数形态（后端接缝）：[LlmService] 按模式把 `ask` 委派给其一。
///
/// 测试注入 fake 即可覆盖模式路由与解析容错，无需真实引擎 / 网络。
typedef SingleShotAsk = Future<String> Function({
  required String system,
  required String user,
  int? maxTokens,
});

/// [Llm] 的唯一实现（设计文档方案 B：无 static instance）。
///
/// 唯一性来自「`main()` 只构造一次 + Provider 树持有」；业务依赖 [Llm]
/// 接口，不感知本类。持服务资源态（当前模式解析 / 后端接缝），
/// **不持任何业务语义状态**。
///
/// - **单一模式来源**：[ChatMode] 只在本类解析（每次调用时读设置，
///   入口复核兜底——Task 4 再补设置变更通知）；
/// - **确保就绪是入口职责**：本地缺模型 / 云端缺配置都在 `ask` 路径上
///   抛带语义的异常，调用方无需预热；
/// - **解析容错唯一落点**：[askJson] 的剥 think / 围栏 / 刮 JSON 双后端共用。
class LlmService implements Llm {
  final SettingsRepository _settings;

  /// 后端接缝；null 时用生产默认（云端 [CloudCompletion] / 本地 llama.cpp）。
  final SingleShotAsk? _cloudAsk;
  final SingleShotAsk? _localAsk;

  /// [settings] 缺省用仓库单例；[cloudAsk] / [localAsk] 仅测试注入。
  LlmService({
    SettingsRepository? settings,
    SingleShotAsk? cloudAsk,
    SingleShotAsk? localAsk,
  })  : _settings = settings ?? SettingsRepository.instance,
        _cloudAsk = cloudAsk, // ignore: prefer_initializing_formals
        _localAsk = localAsk; // ignore: prefer_initializing_formals

  /// 启动期初始化（composition root 调用，异步不卡首帧）。
  ///
  /// Task 2 现阶段仅记录解析出的模式；Task 4 扩展为：本地模式主动预热
  /// 引擎 + 订阅设置变更（窄 Listenable，切云端延迟释放）。
  Future<void> initialize() async {
    AppLogger.info('LlmService',
        '初始化完成，当前模式: ${_settings.chatCloudMode ? 'cloud' : 'local'}');
  }

  @override
  Future<String> ask({
    required String system,
    required String user,
    int? maxTokens,
  }) async {
    // async：模式解析 / 就绪校验的同步抛错也收敛为 Future 错误，
    // 调用方（业务）只面对一种失败形态。
    final completer = _resolveCompleter();
    return completer(system: system, user: user, maxTokens: maxTokens);
  }

  /// JSON-only 约束：追加到 system 末尾（与各业务的提示词正交）。
  static const _jsonOnlyDirective =
      '\n\n只输出 JSON 本体：禁止 markdown 代码块围栏，禁止任何解释文字。';

  @override
  Future<Map<String, dynamic>?> askJson({
    required String system,
    required String user,
    int? maxTokens,
  }) async {
    final raw = await ask(
      system: system + _jsonOnlyDirective,
      user: user,
      maxTokens: maxTokens,
    );
    final parsed = parseJsonReply(raw);
    AppLogger.info('LlmService',
        parsed != null ? 'askJson 解析成功（${parsed.keys.length} 个顶层键）' : 'askJson 未能解析出 JSON');
    return parsed;
  }

  @override
  bool get isReady => _settings.chatCloudMode
      ? _settings.isCloudApiConfigured
      : LlamaService.instance.hasLoadedEngine;

  // ─── 模式解析（唯一出处）───

  /// **唯一的模式解析点**：每次调用时读设置（入口复核——即使将来通知
  /// 漏发，这里也不会用错后端）。云端模式要求三件套齐全，否则抛语义异常。
  SingleShotAsk _resolveCompleter() {
    if (_settings.chatCloudMode) {
      if (!_settings.isCloudApiConfigured) {
        throw StateError('云端模式未配置完整（地址 / Key / 模型名），请先在设置中补全');
      }
      return _cloudAsk ?? _defaultCloudAsk;
    }
    return _localAsk ?? _defaultLocalAsk;
  }

  /// 云端默认实现：按调用时的 BYOK 配置现建（改配置即时生效，无需重建服务）。
  Future<String> _defaultCloudAsk({
    required String system,
    required String user,
    int? maxTokens,
  }) {
    final completion = CloudCompletion(
      baseUrl: _settings.cloudApiBaseUrl,
      apiKey: _settings.cloudApiKey,
      modelName: _settings.cloudModelName,
    );
    return completion
        .complete(system: system, user: user, maxTokens: maxTokens)
        .then((text) => stripThinkTags(text));
  }

  /// 本地默认实现：按调用时的 GPU 设置确保引擎就绪（模型未下载在此抛错），
  /// 一次性独立 session 补全后释放。
  ///
  /// sampler 取单次补全的后端默认（temperature 0.3 + topP 0.8 +
  /// repeatPenalty 1.1，沿用提取器既有调参）；`maxTokens` 缺省 512。
  Future<String> _defaultLocalAsk({
    required String system,
    required String user,
    int? maxTokens,
  }) async {
    final engine = await LlamaService.instance
        .ensureReady(gpuLayers: _settings.gpuLayers);
    final chat = await engine.createChat();
    return completeText(
      chat,
      system: system,
      user: user,
      sampler: const SamplerParams(
        temperature: 0.3,
        topP: 0.8,
        repeatPenalty: 1.1,
      ),
      maxTokens: maxTokens ?? 512,
      stripThink: true,
    );
  }
}

/// 解析容错（设计附录 A1 的唯一落点）：剥 think → 剥围栏 → 刮首段 `{...}`。
///
/// 纯函数，双后端共用。返回 null = 确实给不出可解析 JSON。
Map<String, dynamic>? parseJsonReply(String raw) {
  var text = stripThinkTags(raw).trim();
  if (text.isEmpty) return null;

  // 剥 markdown 代码围栏（```json ... ```）。
  final fence =
      RegExp(r'^```[a-zA-Z]*\s*([\s\S]*?)\s*```$').firstMatch(text);
  if (fence != null) text = fence.group(1)!;

  // 先直解；失败再刮首段 `{` 到末段 `}`（模型常在前后带说明文字）。
  final direct = _tryDecode(text);
  if (direct != null) return direct;

  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start >= 0 && end > start) {
    return _tryDecode(text.substring(start, end + 1));
  }
  return null;
}

Map<String, dynamic>? _tryDecode(String text) {
  try {
    final value = jsonDecode(text);
    return value is Map<String, dynamic> ? value : null;
  } catch (_) {
    return null;
  }
}
