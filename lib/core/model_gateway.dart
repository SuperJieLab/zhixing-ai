import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:zhixing_ai/core/context/cloud_context_policy.dart';
import 'package:zhixing_ai/core/context/context_assembly.dart';
import 'package:zhixing_ai/core/context/context_budget.dart';
import 'package:zhixing_ai/core/context/local_context_policy.dart';
import 'package:zhixing_ai/core/context/summary_prompt.dart';
import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/llm/engine/llama_template_estimator.dart';
import 'package:zhixing_ai/core/llm/generation/generation.dart';
import 'package:zhixing_ai/core/llm/llm.dart';
import 'package:zhixing_ai/core/logger.dart';

/// 业务唯一门面（design D1–D6，大模型服务分层 v2）。
///
/// 双面职责：
/// - **对话面（有状态）**：持 [ContextState] 实例，编排 装配 → 生成 → 溢出
///   自愈；压缩策略对业务不感知；
/// - **补全面（无状态）**：`ask` / `askJson` / `stop` / `readiness` 一行
///   透传 `Llm`，输入预算守门由 llm 基建的补全唯一通道承担（透传自动获得）。
///
/// 依赖形态（星形）：本类是唯一同时认识 `context`（纯语义：策略/状态）与
/// `llm`（后端接缝）的组合点，两域互相零依赖——端侧度量器与摘要传输在
/// 此注入 context 域。`ChatMode` 仍只在 [Llm] 唯一解析，本类经注入的
/// [modeSource] 消费现值，不自读设置。
///
/// 业务禁止 import `Llm` / `LlmService` / `core/context` 类型——公开类型
/// 经下方 re-export 提供。
export 'package:zhixing_ai/core/llm/llm.dart'
    show ChatMode, LlmPhase, LlmReadiness;

/// 摘要传输实现（llm 侧 → context 域 `ConversationSummarizer` 的适配）：
/// 提示词（`buildSummaryPrompt`，context 域）+ 传输（`Llm.ask`，按模式路由）。
///
/// 原 `SingleShotSummarizer` 独立文件（T7 内聚）：实现同时依赖两个域的
/// 类型，只能住在唯一同时认识两域的网关里。
class AskSummarizer implements ConversationSummarizer {
  /// 摘要请求的输出上限：摘要目标 ≤200 字，512 足够且省钱。
  static const int maxTokens = 512;

  final Future<String> Function({
    required String system,
    required String user,
    int? maxTokens,
  }) _ask;

  const AskSummarizer(this._ask);

  @override
  Future<String> summarize(
      String previousSummary, List<ChatMessage> evicted) async {
    // think 剥离由通道实现负责（双端均已在 `ask` 的默认实现中处理），
    // 本类不做二次加工。摘要失败异常原样上抛，由装配骨架兜底回落。
    //
    // 诊断：端侧摘要是一次**完整推理**（纯 CPU 下可达数十秒），且发生在
    // 用户发出消息之后、首个 token 之前——「首轮长时间无输出」若源于此，
    // 只有这条日志能坐实，故必须记耗时。
    final sw = Stopwatch()..start();
    try {
      final out = await _ask(
        system: buildSummaryPrompt(
          previousSummary: previousSummary,
          dropped: evicted
              .map((m) => (role: m.role.name, content: m.content))
              .toList(),
        ),
        user: '请输出摘要。',
        maxTokens: maxTokens,
      );
      AppLogger.info('AskSummarizer',
          '摘要完成: 挤出 ${evicted.length} 条 → 输出 ${out.length} 字，'
          '耗时 ${_seconds(sw)}');
      return out;
    } catch (e) {
      AppLogger.warn('AskSummarizer',
          '摘要失败（回落旧摘要，移出内容丢弃）: 挤出 ${evicted.length} 条，'
          '耗时 ${_seconds(sw)} — $e');
      rethrow;
    }
  }

  static String _seconds(Stopwatch sw) =>
      '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s';
}

/// 业务唯一门面：对话编排 + 单次补全透传。
class ModelGateway {
  /// [policyFactory] / [deliveryFactory] 仅测试注入；null 时按模式解析生产
  /// 实现（策略内置参数档案，摘要统一走 [Llm.ask]——D4）。
  ///
  /// [deliveryFactory] 每轮调用、网关**不缓存**其结果（稳定实例语义由工厂
  /// 自己承担：生产侧是 `LlmService.deliveryFor` 的池化 + BYOK 指纹重建，
  /// 测试侧返回自持的稳定 fake）。
  ModelGateway({
    required Llm llm,
    required ValueListenable<ChatMode> modeSource,
    ContextPolicy Function(ChatMode mode)? policyFactory,
    FutureOr<ChatGeneration> Function()? deliveryFactory,
  })        : _llm = llm, // ignore: prefer_initializing_formals
        _modeSource = modeSource, // ignore: prefer_initializing_formals
        _policyFactory = policyFactory, // ignore: prefer_initializing_formals
        _deliveryFactory = deliveryFactory { // ignore: prefer_initializing_formals
    // D3：模式变更 → 窗口游标与挤出记账重置（摘要正文跨模式保留）。
    _modeSource.addListener(_onModeChanged);
  }

  final Llm _llm;
  final ValueListenable<ChatMode> _modeSource;
  final ContextPolicy Function(ChatMode mode)? _policyFactory;
  final FutureOr<ChatGeneration> Function()? _deliveryFactory;

  /// 会话压缩状态（自业务收回；实例在此私有，类型在基建）。
  final ContextState _state = ContextState();

  /// [_state] 当前所属的会话标识（见 [converse] 的 `sessionId`）。
  String? _sessionId;

  /// 无状态策略实例（惰性各建一次；双端差异只剩度量 + 预算，D4）。
  ContextPolicy? _localPolicy;
  ContextPolicy? _cloudPolicy;

  void _onModeChanged() {
    final before = _state.k;
    _state.resetWindow();
    AppLogger.info('ModelGateway',
        '模式切换，窗口状态已重置（游标 $before → 0，摘要保留 '
        '${_state.summary.isEmpty ? '无' : '${_state.summary.length}字'}）');
  }

  /// 释放订阅（App 生命周期内通常不调用；测试清理用）。状态与策略随实例
  /// 丢弃，无引擎资源（资源归 [Llm] 侧）。
  void dispose() {
    _modeSource.removeListener(_onModeChanged);
  }

  // ─── 对话面（有状态）───

  /// 一轮对话：给**完整历史**（尾部为本轮新用户消息），回文本流。
  ///
  /// 编排：会话切换复位 → 装配（含压缩，就地更新私有 [_state]）→ 交付
  /// （流式）→ 溢出自愈。端侧溢出（context full）在此承接：强制收缩 →
  /// 重新装配 → 预置会话（下一轮直接可用），本轮以兜底文案收尾。
  ///
  /// [sessionId] 为**会话身份**（业务给，同一会话内稳定、跨会话必不同）：
  /// 与上次不同即整体作废压缩状态（摘要卡 + 游标都只属于上一个会话）。
  /// 此前只靠装配期的「历史变短 / 游标越界」兜底——**新会话比上次更长时
  /// 两条都不成立**，上个会话的摘要卡会被当作本会话的「此前对话摘要」注入，
  /// 游标错位，首轮还可能因此多跑一次摘要推理（端侧表现为长时间无输出）。
  /// 会话边界只有业务知道，故由调用方显式声明；缺省（null）视作同一会话。
  ///
  /// **必须用 `await for` 而非 `yield*`**：`yield*` 委托时内层流的错误直接
  /// 转投输出流、绕过本 try（v1 曾因此让端侧溢出自愈静默失效，单测抓住）。
  Stream<String> converse(
    List<ChatMessage> history, {
    required String systemPrompt,
    String? sessionId,
  }) async* {
    if (sessionId != _sessionId) {
      final hadState = _state.k != 0 || _state.summary.isNotEmpty;
      _state.reset();
      _sessionId = sessionId;
      if (hadState) {
        AppLogger.info('ModelGateway',
            '会话切换（${sessionId ?? '未命名'}），摘要与窗口游标已重置');
      }
    }

    final policy = _policyFor(_modeSource.value);
    final delivery = await _deliveryFor();
    final assembled =
        await policy.assemble(history, state: _state, systemPrompt: systemPrompt);
    AppLogger.info('ModelGateway', _assembleTrace(assembled));

    try {
      await for (final token
          in delivery.deliver(assembled, systemPrompt: systemPrompt)) {
        yield token;
      }
    } on LlmContextOverflowException {
      AppLogger.warn('ModelGateway', '端侧上下文撑爆，强制收缩后重放');
      try {
        policy.handleOverflow(_state);
        final healed = await policy.assemble(history,
            state: _state, systemPrompt: systemPrompt);
        // 二次重放不再判定尾部去重（isDuplicate 有状态，本轮已判定过）
        delivery.prime(healed, systemPrompt: systemPrompt, nudgeTail: false);
      } catch (re) {
        AppLogger.error('ModelGateway', '自愈重放失败', re);
      }
      yield kLlmFailureReply;
    }
  }

  /// 装配诊断行（排查上下文类问题的第一现场）。
  ///
  /// 四个维度缺一不可：**条数**看窗口大小、**用量/预算**看余量（只报条数
  /// 无法判断离爆窗多远）、**本轮挤出**看压缩是否刚发生（突发行为，累计
  /// 游标看不出）、**摘要长度**看压缩产物是否在膨胀。
  String _assembleTrace(AssembledContext a) {
    final pct = a.budget == 0 ? 0 : (a.estimatedCost * 100 / a.budget).round();
    final card = a.summaryCard;
    return '装配[${_modeSource.value.name}]: 窗口 ${a.messages.length} 条'
        ' · 用量 ${a.estimatedCost}/${a.budget} ($pct%)'
        ' · 摘要 ${card == null ? '无' : '${card.length}字'}'
        ' · 游标 k=${_state.k}'
        '${a.evictedCount > 0 ? ' · 本轮挤出 ${a.evictedCount} 条' : ''}';
  }

  /// 按模式现选策略（D2：每轮现取模式源现值，切换下一轮自然生效）。
  ContextPolicy _policyFor(ChatMode mode) {
    final factory = _policyFactory;
    if (factory != null) return factory(mode);
    return switch (mode) {
      // 度量器按端注入（llama 知识不进 context 域）；摘要统一走 llm.ask（D4）
      ChatMode.cloud => _cloudPolicy ??= CloudContextPolicy(
          summarizer: AskSummarizer(_llm.ask),
        ),
      ChatMode.local => _localPolicy ??= LocalContextPolicy(
          estimator: LlamaTemplateEstimator(),
          summarizer: AskSummarizer(_llm.ask),
        ),
    };
  }

  Future<ChatGeneration> _deliveryFor() {
    final factory = _deliveryFactory;
    if (factory != null) return Future.sync(factory);
    // 生产缺省：交付解析委托 LlmService（池化 + BYOK 指纹重建在 llm 域）。
    return Future.error(StateError(
        'ModelGateway 缺少交付工厂：composition root 须注入 '
        'LlmService.deliveryFor（T3 过渡期），或后续由 llm 域直接提供'));
  }

  // ─── 补全面（无状态透传；守门在 llm 基建自动生效）───

  /// 透传纪律（D5）：以下成员一律一行委托，禁止长出任何逻辑。
  Future<String> ask({
    required String system,
    required String user,
    int? maxTokens,
  }) =>
      _llm.ask(system: system, user: user, maxTokens: maxTokens);

  /// 单次补全的输入截断（plan 偏差②的例外收口）。
  ///
  /// 单次调用的上下文管理是「简单态」：无摘要、无状态，只做预算内尾部
  /// 装箱。此前 `StrategistExtractor` 直连装箱原语 + 度量器 + 预算常量
  /// （业务触碰 context/llm 内件的唯一例外），现收口到门面——业务给
  /// 完整消息列表 + 提示词，拿预算内结果，不感知度量口径与预算值。
  ///
  /// 预算扣除 [system] 与 [prefix]（调用方将拼在 user 里的附加文本，如
  /// 已有目标清单）的占用；度量口径随当前模式（本地 token / 云端字符），
  /// 与补全守门同源。[minKeep] 语义同 `packTailWithinBudget`（单次提取
  /// 无「当前问题」须保底，缺省 0 = 最坏保留 0 条）。
  List<ChatMessage> truncateForAsk(
    List<ChatMessage> messages, {
    required String system,
    String? prefix,
    int minKeep = 0,
  }) {
    final mode = _modeSource.value;
    final (estimator, budget) = switch (mode) {
      ChatMode.local => (LlamaTemplateEstimator(), AppConstants.localInputBudget),
      ChatMode.cloud => (CharCountEstimator(), AppConstants.cloudInputBudget),
    };
    final overhead = estimator.estimateText(system) +
        (prefix == null ? 0 : estimator.estimateText(prefix));
    final pack = packTailWithinBudget(
      messages,
      budget: budget,
      estimator: estimator,
      baseCost: overhead,
      minKeep: minKeep,
    );
    AppLogger.info('ModelGateway',
        'truncateForAsk(${mode.name}): overhead=$overhead, budget=$budget, '
        '保留 ${pack.kept.length}/${messages.length} 条');
    return pack.kept;
  }

  Future<Map<String, dynamic>?> askJson({
    required String system,
    required String user,
    int? maxTokens,
  }) =>
      _llm.askJson(system: system, user: user, maxTokens: maxTokens);

  void stop() => _llm.stop();

  /// 确保后端就绪（幂等透传；页面失败重试触发兜底加载用）。
  Future<void> ensureReady() => _llm.ensureReady();

  bool get isReady => _llm.isReady;

  ValueListenable<LlmReadiness> get readiness => _llm.readiness;
}
