import 'dart:convert';

import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;

import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/data/repository/settings_repository.dart';
import 'package:zhixing_ai/core/llm/cloud_completion.dart';
import 'package:zhixing_ai/core/llm/cloud_context_policy.dart';
import 'package:zhixing_ai/core/llm/context_assembly.dart';
import 'package:zhixing_ai/core/llm/delivery/chat_delivery.dart';
import 'package:zhixing_ai/core/llm/delivery/cloud_delivery.dart';
import 'package:zhixing_ai/core/llm/delivery/local_delivery.dart';
import 'package:zhixing_ai/core/llm/inference.dart';
import 'package:zhixing_ai/core/llm/llama_service.dart';
import 'package:zhixing_ai/core/llm/llm.dart';
import 'package:zhixing_ai/core/llm/local_context_policy.dart';
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

  /// 转换 / 交付接缝（**仅测试注入**）；null 时按模式解析生产实现。
  ///
  /// 端侧引擎与 `EngineChat` 均为 `final class` 无法 fake，故用函数接缝让
  /// [converse] 的编排（装配 → 交付 → 溢出承接自愈）可单测——与
  /// [SingleShotAsk] 同一思路。
  final ContextPolicy Function()? _policyFactory;
  final ChatDelivery Function()? _deliveryFactory;

  /// 端侧引擎句柄（服务资源态：不持它就无法加载 / 释放）。
  LlamaEngine? _localEngine;

  /// 交付实现（服务资源态）。云端按 BYOK 指纹重建，本地复用同一会话。
  LocalDelivery? _localDelivery;
  CloudDelivery? _cloudDelivery;
  String? _cloudFingerprint;

  /// 测试接缝交付实例：惰性建一次并复用（与生产「稳定实例」语义一致）。
  ChatDelivery? _overrideDelivery;

  /// [settings] 缺省用仓库单例；其余接缝（[cloudAsk] / [localAsk] /
  /// [policyFactory] / [deliveryFactory]）仅测试注入。
  LlmService({
    SettingsRepository? settings,
    SingleShotAsk? cloudAsk,
    SingleShotAsk? localAsk,
    ContextPolicy Function()? policyFactory,
    ChatDelivery Function()? deliveryFactory,
  })  : _settings = settings ?? SettingsRepository.instance,
        _cloudAsk = cloudAsk, // ignore: prefer_initializing_formals
        _localAsk = localAsk, // ignore: prefer_initializing_formals
        _policyFactory = policyFactory, // ignore: prefer_initializing_formals
        _deliveryFactory = deliveryFactory; // ignore: prefer_initializing_formals

  /// 启动期初始化（composition root 调用，异步不卡首帧）。
  ///
  /// Task 3 现阶段仅记录解析出的模式；Task 4 扩展为：本地模式主动预热
  /// 引擎 + 订阅设置变更（窄 Listenable，切云端延迟释放）。
  Future<void> initialize() async {
    AppLogger.info('LlmService',
        '初始化完成，当前模式: ${_settings.chatCloudMode ? 'cloud' : 'local'}');
  }

  // ─── 对话（多轮）───

  /// 服务内部编排上下文交付链：入口确保就绪 → 转换（装配）→ 交付 → 取回。
  ///
  /// 端侧溢出（context full）在此承接自愈：强制收缩 → 重新装配 →
  /// 预置会话（下一轮直接可用），本轮以兜底文案收尾。
  @override
  Stream<String> converse(
    List<ChatMessage> history, {
    required String systemPrompt,
    required ContextState state,
  }) async* {
    final policy = await _policyFor();
    final delivery = await _deliveryFor();
    final assembled = await policy.assemble(
      history,
      state: state,
      systemPrompt: systemPrompt,
    );

    try {
      // **必须用 `await for` 而非 `yield*`**：`yield*` 委托时内层流的错误会直
      // 接转投到输出流，**绕过本 try**，下面的溢出承接将永远不触发。`await for`
      // 才会把内层错误抛进本函数的 try 作用域（用 `yield*` 的写法曾被单测当场
      // 抓住——自愈静默失效）。
      await for (final token
          in delivery.deliver(assembled, systemPrompt: systemPrompt)) {
        yield token;
      }
    } on LlmContextOverflowException {
      AppLogger.warn('LlmService', '端侧上下文撑爆，强制收缩后重放');
      try {
        policy.handleOverflow(state);
        final healed = await policy.assemble(
          history,
          state: state,
          systemPrompt: systemPrompt,
        );
        // 二次重放不再判定尾部去重（isDuplicate 有状态，本轮已判定过）
        delivery.prime(healed, systemPrompt: systemPrompt, nudgeTail: false);
      } catch (re) {
        AppLogger.error('LlmService', '自愈重放失败', re);
      }
      yield kLlmFailureReply;
    }
  }

  @override
  void stop() {
    _overrideDelivery?.stop();
    _localDelivery?.stop();
    _cloudDelivery?.stop();
  }

  @override
  Future<void> ensureReady() async {
    if (_settings.chatCloudMode) {
      _requireCloudConfigured();
      return;
    }
    await _localDeliveryFor();
  }

  @override
  bool get isReady => _settings.chatCloudMode
      ? _settings.isCloudApiConfigured
      : (_localDelivery?.isReady ?? false);

  // ─── 单次补全 ───

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

  // ─── 模式解析（唯一出处）───

  /// **唯一的模式解析点**：每次调用时读设置（入口复核——即使将来通知
  /// 漏发，这里也不会用错后端）。
  ChatMode get _mode =>
      _settings.chatCloudMode ? ChatMode.cloud : ChatMode.local;

  void _requireCloudConfigured() {
    if (!_settings.isCloudApiConfigured) {
      throw StateError('云端模式未配置完整（地址 / Key / 模型名），请先在设置中补全');
    }
  }

  /// 转换段：按模式给出后端策略（度量 + 预算 + 摘要实现）。
  Future<ContextPolicy> _policyFor() async {
    final override = _policyFactory;
    if (override != null) return override();
    if (_mode == ChatMode.cloud) {
      _requireCloudConfigured();
      return CloudContextPolicy(
        baseUrl: _settings.cloudApiBaseUrl,
        apiKey: _settings.cloudApiKey,
        modelName: _settings.cloudModelName,
      );
    }
    final engine = await _ensureLocalEngine();
    return LocalContextPolicy(summarizer: LlamaSummarizer(engine));
  }

  /// 交付段：按模式给出交付实现（模式出口，业务不可见）。
  Future<ChatDelivery> _deliveryFor() async {
    final override = _deliveryFactory;
    // 惰性建一次并复用：交付实现是「稳定实例」（端侧靠它复用同一会话）
    if (override != null) return _overrideDelivery ??= override();
    if (_mode == ChatMode.cloud) {
      _requireCloudConfigured();
      final fingerprint = '${_settings.cloudApiBaseUrl}\u0000'
          '${_settings.cloudApiKey}\u0000${_settings.cloudModelName}';
      if (_cloudDelivery == null || _cloudFingerprint != fingerprint) {
        _cloudDelivery?.dispose();
        _cloudDelivery = CloudDelivery(
          baseUrl: _settings.cloudApiBaseUrl,
          apiKey: _settings.cloudApiKey,
          modelName: _settings.cloudModelName,
        );
        _cloudFingerprint = fingerprint;
      }
      return _cloudDelivery!;
    }
    return _localDeliveryFor();
  }

  Future<LocalDelivery> _localDeliveryFor() async {
    final engine = await _ensureLocalEngine();
    final delivery = _localDelivery ??=
        LocalDelivery(sessionFactory: () => engine.createChat().then(LlamaChatSession.new));
    await delivery.ensureReady();
    return delivery;
  }

  Future<LlamaEngine> _ensureLocalEngine() async {
    final engine = _localEngine;
    if (engine != null) return engine;
    _localEngine =
        await LlamaService.instance.ensureReady(gpuLayers: _settings.gpuLayers);
    return _localEngine!;
  }

  /// 单次补全的后端接缝：模式解析（唯一出处）+ 就绪校验。
  SingleShotAsk _resolveCompleter() {
    if (_mode == ChatMode.cloud) {
      _requireCloudConfigured();
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
