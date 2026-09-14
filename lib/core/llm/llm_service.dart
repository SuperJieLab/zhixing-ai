import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;

import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/data/repository/settings_repository.dart';
import 'package:zhixing_ai/core/llm/active_model_manager.dart';
import 'package:zhixing_ai/core/llm/cloud_completion.dart';
import 'package:zhixing_ai/core/llm/cloud_context_policy.dart';
import 'package:zhixing_ai/core/llm/context_assembly.dart';
import 'package:zhixing_ai/core/llm/delivery/chat_delivery.dart';
import 'package:zhixing_ai/core/llm/delivery/cloud_delivery.dart';
import 'package:zhixing_ai/core/llm/delivery/local_delivery.dart';
import 'package:zhixing_ai/core/llm/inference.dart';
import 'package:zhixing_ai/core/llm/input_guard.dart';
import 'package:zhixing_ai/core/llm/llama_service.dart';
import 'package:zhixing_ai/core/llm/llm.dart';
import 'package:zhixing_ai/core/llm/local_context_policy.dart';
import 'package:zhixing_ai/core/llm/single_shot_summarizer.dart';
import 'package:zhixing_ai/core/llm/think_tag_stripper.dart';
import 'package:zhixing_ai/core/logger.dart';

/// 后端接缝类型自 [single_shot_summarizer] 迁入处再导出（既有测试从本文件
/// import 该 typedef，保持兼容）。
export 'package:zhixing_ai/core/llm/single_shot_summarizer.dart'
    show SingleShotAsk;

/// 本地交付构造接缝（**仅测试注入**）：生命周期测试用它替代真实引擎加载
/// （`LlamaEngine` 是 final class，无法 fake；与 [SingleShotAsk] 同一思路）。
typedef LocalDeliveryBuilder = FutureOr<ChatDelivery> Function();

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

  /// 交付实现（服务资源态）。云端按 BYOK 指纹重建，本地复用同一会话。
  /// 本地引擎本体不在此缓存——`LlamaService` 池按 config 键控持有（幂等 +
  /// 并发去重），这里再存一份是双份记账，且 GPU 设置变更后会返回旧引擎。
  ChatDelivery? _localDelivery;
  CloudDelivery? _cloudDelivery;
  String? _cloudFingerprint;

  /// 本地交付的在途构建 Future（并发 ensure 去重 + 失败不缓存可重试）。
  Future<ChatDelivery>? _localReady;

  /// 就绪态通知源（服务资源态）：冷启动预热 / [ensureReady] / 模式切换时更新。
  final ValueNotifier<LlmReadiness> _readiness =
      ValueNotifier<LlmReadiness>(const LlmReadiness.idle());

  /// 切云端后本地资源的延迟释放定时器（防抖：连续切换只保留最后一次）。
  Timer? _releaseTimer;

  /// 本地交付构造接缝；null 时按生产默认（真实引擎）。
  final LocalDeliveryBuilder? _localDeliveryBuilder;

  /// 切云端后本地资源的延迟释放时长（design 附录 A3 的可调参数）。
  ///
  /// 给「误切后切回」留缓冲：防抖窗口内切回本地则完全不动引擎。
  final Duration _delayedRelease;

  /// 测试接缝交付实例：惰性建一次并复用（与生产「稳定实例」语义一致）。
  ChatDelivery? _overrideDelivery;

  /// 最近一次本地引擎加载时的模型路径。模型切换时据此识别「需要释放的是
  /// 哪个 config 的池条目」——切换后 `defaultModelPath` 已是新值，不记录
  /// 旧路径就会放跑旧条目（引擎驻留内存）。
  String? _loadedModelPath;

  /// 模型变更通知源；仅测试注入（默认 [ActiveModelManager.instance]）。
  final ChangeNotifier _modelChanges;

  /// [settings] 缺省用仓库单例；其余接缝（[cloudAsk] / [localAsk] /
  /// [policyFactory] / [deliveryFactory] / [localDeliveryBuilder]）仅测试注入。
  LlmService({
    SettingsRepository? settings,
    SingleShotAsk? cloudAsk,
    SingleShotAsk? localAsk,
    ContextPolicy Function()? policyFactory,
    ChatDelivery Function()? deliveryFactory,
    LocalDeliveryBuilder? localDeliveryBuilder,
    Duration delayedRelease = const Duration(seconds: 30),
    ChangeNotifier? modelChanges,
  })  : _settings = settings ?? SettingsRepository.instance,
        _modelChanges = modelChanges ?? ActiveModelManager.instance,
        _cloudAsk = cloudAsk, // ignore: prefer_initializing_formals
        _localAsk = localAsk, // ignore: prefer_initializing_formals
        _policyFactory = policyFactory, // ignore: prefer_initializing_formals
        _deliveryFactory = deliveryFactory, // ignore: prefer_initializing_formals
        _localDeliveryBuilder = localDeliveryBuilder, // ignore: prefer_initializing_formals
        _delayedRelease = delayedRelease; // ignore: prefer_initializing_formals

  /// 启动期初始化（composition root 调用，`unawaited` 异步不卡首帧）。
  ///
  /// ① 订阅设置的后端通知源（窄 `Listenable`）——此后用户切模式 / 改
  /// BYOK 三件套，服务即时切换 / 重建资源（本地引擎延迟释放 + 防抖）；
  /// ② 订阅活跃模型变更——切模型时旧引擎资源立即拆除（见 [_onActiveModelChanged]）；
  /// ③ 按当前模式预热：本地 → 异步加载引擎；云端 → 校验 BYOK 三件套。
  /// 失败不抛（就绪态转 failed，由 UI 表达；页面进入时还有异步兜底）。
  Future<void> initialize() async {
    _settings.backendListenable.addListener(_onBackendSettingChanged);
    _modelChanges.addListener(_onActiveModelChanged);
    try {
      await ensureReady();
    } catch (e) {
      AppLogger.warn('LlmService', '启动预热失败（就绪态已转 failed）: $e');
    }
  }

  /// 活跃模型变更（下载完成 / 用户切换模型）的响应。
  ///
  /// 「使用新模型」**即刻生效**：旧模型引擎连同其上的会话立即废弃（无
  /// 「误切回旧模型再切回」的场景，不需要云端切换那套延迟释放防抖）。
  /// 后果：切换瞬间若有在途生成，该轮以错误收尾；下一轮自动加载新模型。
  void _onActiveModelChanged() {
    final loaded = _loadedModelPath;
    final current = AppConstants.defaultModelPath;
    if (loaded == null || loaded == current) return;
    _loadedModelPath = null;
    _teardownLocalResources(modelPath: loaded);
    AppLogger.info('LlmService', '活跃模型切换（$loaded → $current），旧引擎资源已拆除');
    if (!_settings.chatCloudMode) {
      unawaited(ensureReady().catchError((Object _) {}));
    }
  }

  /// 后端相关设置变更的响应（窄通知，design §10.1 #1）。
  ///
  /// - 切云端 / 改 BYOK：旧云端交付按指纹即刻废弃（下次使用按新配置重建）；
  ///   本地资源**延迟释放 + 防抖**（连续切换 / 短暂来回只保留最后一次计时）；
  ///   就绪态按 BYOK 是否配齐直接给出（云端就绪化是瞬时的）。
  /// - 切回本地：取消待执行的释放（防抖的反向），再异步补齐本地就绪。
  void _onBackendSettingChanged() {
    if (_settings.chatCloudMode) {
      final fingerprint = _currentCloudFingerprint;
      if (_cloudFingerprint != null && _cloudFingerprint != fingerprint) {
        _cloudDelivery?.dispose();
        _cloudDelivery = null;
        _cloudFingerprint = null;
      }
      if (_localDelivery != null ||
          _localReady != null ||
          LlamaService.instance.hasLoadedEngine) {
        _releaseTimer?.cancel();
        _releaseTimer = Timer(_delayedRelease, _releaseLocalResources);
        AppLogger.info('LlmService',
            '切至云端，本地引擎将在 ${_delayedRelease.inMilliseconds}ms 后释放（防抖）');
      }
      if (_settings.isCloudApiConfigured) {
        _setReadiness(const LlmReadiness.ready());
      } else {
        _setReadiness(LlmReadiness.failed(StateError(
            '云端模式未配置完整（地址 / Key / 模型名），请先在设置中补全')));
      }
    } else {
      _releaseTimer?.cancel();
      _releaseTimer = null;
      unawaited(ensureReady().catchError((Object _) {}));
    }
  }

  /// 延迟释放到点：丢弃并释放本地交付与引擎。仅在云端模式下执行
  /// （定时器只应在该模式下存在；防御通知漏发导致的误释放）。
  void _releaseLocalResources() {
    _releaseTimer = null;
    if (!_settings.chatCloudMode) return;
    _teardownLocalResources();
    AppLogger.info('LlmService', '云端模式下本地引擎已延迟释放');
  }

  /// 本地资源统一拆除（延迟释放 / 模型切换 / 服务 dispose 共用）。
  ///
  /// 引擎释放**必须走 [LlamaService.release] 的池失效**——直接
  /// `engine.dispose()` 会留下「池缓存已释放引擎」的脏条目，切回本地时
  /// ensureReady 命中缓存返回死引擎，本地模式从此永久损坏。
  ///
  /// [modelPath] 为要释放的池条目路径；缺省回退当前活跃模型路径
  /// （模型切换场景必须显式传旧路径，见 [_onActiveModelChanged]）。
  void _teardownLocalResources({String? modelPath}) {
    _localReady = null;
    _localDelivery?.dispose();
    _localDelivery = null;
    unawaited(LlamaService.instance
        .release(modelPath: modelPath, gpuLayers: _settings.gpuLayers)
        .catchError((_) {}));
  }

  /// 释放服务资源与订阅（App 生命周期内通常不调用；测试清理用）。
  void dispose() {
    _settings.backendListenable.removeListener(_onBackendSettingChanged);
    _modelChanges.removeListener(_onActiveModelChanged);
    _releaseTimer?.cancel();
    _releaseTimer = null;
    _teardownLocalResources();
    _cloudDelivery?.dispose();
    _cloudDelivery = null;
    _readiness.dispose();
  }

  void _setReadiness(LlmReadiness value) {
    if (_readiness.value != value) _readiness.value = value;
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
      try {
        _requireCloudConfigured();
      } catch (e) {
        _setReadiness(LlmReadiness.failed(e));
        rethrow;
      }
      _setReadiness(const LlmReadiness.ready());
      return;
    }
    _setReadiness(const LlmReadiness.loading());
    try {
      await _localDeliveryFor();
      // 构建期间切到云端：云端就绪态已由通知源写好（ready/failed），
      // 本地构建的失败/弃置不得覆盖它。
      if (!_settings.chatCloudMode) _setReadiness(const LlmReadiness.ready());
    } catch (e) {
      if (!_settings.chatCloudMode) _setReadiness(LlmReadiness.failed(e));
      rethrow;
    }
  }

  @override
  bool get isReady => _readiness.value.phase == LlmPhase.ready;

  @override
  ValueListenable<LlmReadiness> get readiness => _readiness;

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
    // 输入预算守门（design D5）：补全唯一通道单点施加——`askJson` 经本方法
    // 透传自动覆盖（其 JSON-only directive 固定且极短，随本处一并度量）。
    // 超预算在触达后端前 fail-fast：不发生网络 / 引擎动作。
    ensureInputWithinBudget(mode: _mode, system: system, user: user);
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
  ///
  /// 摘要器统一为 [SingleShotSummarizer]：提示词与输出上限收口在它内部，
  /// 传输走本服务的单次补全通道（本地 `_defaultLocalAsk` / 云端
  /// `_defaultCloudAsk`，或测试注入的接缝）——摘要与 `ask` 共用同一实现，
  /// 不再各自摸后端。
  Future<ContextPolicy> _policyFor() async {
    final override = _policyFactory;
    if (override != null) return override();
    if (_mode == ChatMode.cloud) {
      // 配置校验在 _deliveryFor（交付前最后一道）；摘要通道同理——此处构造的
      // 策略即便带着空配置也不会被使用（converse 在装配前就会因交付校验失败抛错）。
      return CloudContextPolicy(
          summarizer: SingleShotSummarizer(_cloudAsk ?? _defaultCloudAsk));
    }
    return LocalContextPolicy(
        summarizer: SingleShotSummarizer(_localAsk ?? _defaultLocalAsk));
  }

  /// 交付段：按模式给出交付实现（模式出口，业务不可见）。
  Future<ChatDelivery> _deliveryFor() async {
    final override = _deliveryFactory;
    // 惰性建一次并复用：交付实现是「稳定实例」（端侧靠它复用同一会话）
    if (override != null) return _overrideDelivery ??= override();
    if (_mode == ChatMode.cloud) {
      _requireCloudConfigured();
      final fingerprint = _currentCloudFingerprint;
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

  /// BYOK 三件套指纹（任一变更即要求云端交付重建）。
  String get _currentCloudFingerprint => '${_settings.cloudApiBaseUrl}\u0000'
      '${_settings.cloudApiKey}\u0000${_settings.cloudModelName}';

  Future<ChatDelivery> _localDeliveryFor() async {
    final ready = _localReady;
    if (ready != null) return ready;
    final future = _buildLocalDelivery();
    _localReady = future;
    try {
      final delivery = await future;
      // 构建在途时切到了云端：不缓存（延迟释放可能已把资源清掉，缓存即泄漏）。
      // 抛错让调用方走各自路径：ensureReady 由下方按当前模式决定是否回写 failed，
      // converse 由业务降级一轮（下轮起走云端，自愈）。
      if (_settings.chatCloudMode) {
        delivery.dispose();
        if (identical(_localReady, future)) _localReady = null;
        throw StateError('本地构建完成时已切换云端模式，结果弃置');
      }
      _localDelivery = delivery;
      return delivery;
    } catch (e) {
      // 失败不缓存，允许重试（仅当没有更新的构建发起时才清空）。
      if (identical(_localReady, future)) _localReady = null;
      rethrow;
    }
  }

  Future<ChatDelivery> _buildLocalDelivery() async {
    final builder = _localDeliveryBuilder;
    // 记录本次交付所服务的模型路径（模型切换时据此拆除旧资源）。
    _loadedModelPath = AppConstants.defaultModelPath;
    if (builder != null) return builder();
    final engine = await _ensureLocalEngine();
    final delivery = LocalDelivery(
      sessionFactory: () => engine.createChat().then(LlamaChatSession.new),
    );
    await delivery.ensureReady();
    return delivery;
  }

  /// 端侧引擎获取：直走 [LlamaService] 池（按 config 缓存 Future，幂等 +
  /// 并发去重；GPU 设置变更自动落新条目，不存在旧引擎句柄残留）。
  Future<LlamaEngine> _ensureLocalEngine() =>
      LlamaService.instance.ensureReady(gpuLayers: _settings.gpuLayers);

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
