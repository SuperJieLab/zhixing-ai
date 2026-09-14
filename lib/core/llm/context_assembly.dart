import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/llm/context_budget.dart';

/// 转换段（基建）：对话历史 + 会话压缩状态 → 本次请求实际要发送的上下文。
///
/// 从 `features/chat/engine/context/context_policy.dart` 上移 + **状态外置**
/// （2026-09-12 设计 §10.1 #4 拍定 A）：装配算法无状态，会话态由调用方持有的
/// [ContextState] 实例承载——**类型在基建、实例在业务**。
///
/// 本层红线：不得出现任何后端专属概念（nCtx / llama / EngineChat）；双端差异
/// 全部经构造参数注入（度量 / 预算 / 摘要器 / 保底 / 溢出收缩）。

/// 摘要卡的标记前缀（双端一致；交付实现以一条 system 消息注入到人设之后）。
const String kSummaryCardPrefix = '【此前对话摘要】';

/// 装配结果：本次请求要发送的历史 + 可选的摘要卡。
///
/// 交付实现恒以「清空 + 按 [messages] 全量重放」消费（端侧）或现拼请求体
/// （云端），故无需标记本次是否发生窗口收缩。
class AssembledContext {
  /// 已过滤 + 装窗后的历史（保持原顺序，尾部为最近消息）。
  final List<ChatMessage> messages;

  /// 此前对话的滚动摘要卡（含 [kSummaryCardPrefix] 前缀，可直接作为
  /// system 消息注入）；null 表示本会话尚无摘要。
  final String? summaryCard;

  const AssembledContext({
    required this.messages,
    this.summaryCard,
  });

  @override
  String toString() => 'AssembledContext(messages: ${messages.length}, '
      'summaryCard: ${summaryCard == null ? 'none' : '${summaryCard!.length}字'})';
}

/// 会话压缩状态（**实例由业务持有**，类型定义在基建）。
///
/// 采用「方案 A」形态：保留窗口**不被存下来**，只存覆盖游标 [k]——窗口恒为
/// `eligible[k..]`（全量列表的一条后缀），每轮由全量列表现算。⇒ 状态小到可
/// 序列化（将来能持久化 / 随会话迁移），且少一处可能与消息列表漂移的副本。
///
/// [lastEligibleLength] 与 [k] 的两条防御共同保证与「存完整窗口列表」等价：
/// ① 长度比上次**变短** → [reset]；② 游标越界 → [reset]。
class ContextState {
  /// 滚动摘要正文（首次为空串）。
  String summary;

  /// 覆盖游标：保留窗口起点在 eligible 中的下标（前 k 条已折进摘要 / 被丢弃）。
  int k;

  /// 上次装配时 eligible 的长度（历史变短检测）。
  int lastEligibleLength;

  /// 待执行的强制收缩条数（由 [ContextPolicy.handleOverflow] 置位，下次装配生效）。
  int? pendingForceKeep;

  ContextState({
    this.summary = '',
    this.k = 0,
    this.lastEligibleLength = 0,
    this.pendingForceKeep,
  });

  /// 回到初始状态（新对话 / 重新初始化 / 历史回退）。
  void reset() {
    summary = '';
    k = 0;
    lastEligibleLength = 0;
    pendingForceKeep = null;
  }

  /// 仅重置窗口游标与挤出记账，**保留摘要正文**。
  ///
  /// 供后端模式切换使用（design D3）：两端窗口宽度不同（度量单位、预算都
  /// 不同），游标 `k` 跨模式语义会漂；而摘要正文与后端无关，可跨模式保留。
  void resetWindow() {
    k = 0;
    lastEligibleLength = 0;
    pendingForceKeep = null;
  }

  @override
  String toString() => 'ContextState(k: $k, summary: '
      '${summary.isEmpty ? 'none' : '${summary.length}字'}, '
      'lastEligibleLength: $lastEligibleLength)';
}

/// 上下文策略：对话历史 → 实际发送的消息。
///
/// 承载「上下文管理」职责（过滤 / 度量 / 装窗 / 压缩 / 溢出自愈契约），
/// 与「传输 / 推理后端」正交。**实现不得引用任何后端专属概念**。
abstract class ContextPolicy {
  /// 装配本次请求上下文。超预算时内部执行压缩（可能触发 [ConversationSummarizer]）。
  ///
  /// [state] 为会话压缩状态（业务持有并传入，方法内就地更新）。
  /// [systemPrompt] 仅参与**预算核算**（人设与摘要卡占用同一预算），
  /// 不由本策略注入——人设的唯一出处是业务侧的人设构建器，
  /// 由交付实现排列在消息列表最前。
  Future<AssembledContext> assemble(
    List<ChatMessage> history, {
    required ContextState state,
    String systemPrompt = '',
  });

  /// 传输层溢出自愈钩子（如端侧 context full）：请求强制收缩，下次装配生效。
  void handleOverflow(ContextState state);
}

/// 摘要能力（策略位）：把被移出的消息与旧摘要压成新的摘要正文。
abstract class ConversationSummarizer {
  /// [previousSummary] 为旧摘要正文（首次为空串）；[evicted] 为新移出窗口的消息。
  Future<String> summarize(String previousSummary, List<ChatMessage> evicted);
}

// ─── 共享算法（① 过滤：双端同一段代码）───

/// 过滤：剔除无资格进上下文的消息（第 0 轮欢迎语）。
///
/// 欢迎语是客户端展示用的开场白，不属于对话上下文；双端共享同一实现
/// （此前云端过滤、本地隐式全量，是同一逻辑的两处实现）。
List<ChatMessage> filterEligible(List<ChatMessage> history) =>
    history.where((m) => m.round != 0).toList();

/// 共享装配骨架（无状态）：过滤 → 装窗 → 必要时压缩成摘要卡。
///
/// 双端差异**全部**通过构造注入，本类内部不含任何分支化的后端概念：
/// - 度量单位 → [estimator]（策略位②）
/// - 预算大小 → [budget]（本地为物理硬上限，云端可设得远大于需求）
/// - 摘要实现 → [summarizer]（策略位④；null = 无摘要能力，移出即丢弃）
/// - 保底条数 → [minKeep]；溢出收缩 → [overflowKeep]（null = 不收缩）
///
/// **窗口是派生量**（方案 A）：不持有保留列表，只用 `state.k` 记住窗口起点。
/// 挤出时把 `k` 前移 evicted 条数，窗口随即回到预算内 ⇒ 后续若干轮不再触发
/// 压缩（不会每轮都调摘要器），与旧实现（持有 `_retained` 列表）等价。
abstract class BaseContextPolicy implements ContextPolicy {
  BaseContextPolicy({
    required ContextEstimator estimator,
    required this.budget,
    ConversationSummarizer? summarizer,
    this.minKeep = 2,
    this.overflowKeep,
  })  : _estimator = estimator, // ignore: prefer_initializing_formals
        _summarizer = summarizer; // ignore: prefer_initializing_formals

  final ContextEstimator _estimator;
  final ConversationSummarizer? _summarizer;

  /// 输入预算（度量单位由 [estimator] 决定）：历史 + 摘要卡 + 人设都不得超出。
  final int budget;

  /// 装窗保底条数（最近消息，不因预算不足被移出）。
  final int minKeep;

  /// 溢出自愈时强制保留的条数；null = 不收缩（仅保留契约对称）。
  final int? overflowKeep;

  /// 摘要正文长度上限（超出截断，与端侧摘要口径一致）。
  static const summaryCharLimit = 200;

  @override
  void handleOverflow(ContextState state) {
    // null → 无收缩（契约对称，云端策略如此）；非 null → 下次装配硬收缩
    state.pendingForceKeep = overflowKeep;
  }

  @override
  Future<AssembledContext> assemble(
    List<ChatMessage> history, {
    required ContextState state,
    String systemPrompt = '',
  }) async {
    final eligible = filterEligible(history);

    // 两条防御（方案 A 与「存完整窗口」等价的必要条件）：
    // ① 历史变短（换会话 / 异常 / 中间删消息）→ 重置；
    // ② 游标越界 → 重置。
    if (state.k > eligible.length ||
        eligible.length < state.lastEligibleLength) {
      state.reset();
    }
    state.lastEligibleLength = eligible.length;

    // 窗口 = eligible[k..]（派生量，每轮现算）
    final window = eligible.sublist(state.k);

    // 预算核算：人设与上轮摘要卡都要占位
    var baseCost =
        systemPrompt.isEmpty ? 0 : _estimator.estimateText(systemPrompt);
    final prevCard = _card(state.summary);
    if (prevCard != null) baseCost += _estimator.estimateText(prevCard);

    final forceKeep = state.pendingForceKeep;
    state.pendingForceKeep = null;
    final forced = forceKeep != null;

    final pack = forced
        ? packKeepLast(window,
            keep: forceKeep, estimator: _estimator, baseCost: baseCost)
        : packTailWithinBudget(
            window,
            budget: budget,
            estimator: _estimator,
            baseCost: baseCost,
            minKeep: minKeep,
          );

    if (pack.evicted.isNotEmpty) {
      // 挤出后窗口回到预算内：游标前移，后续若干轮不再触发压缩
      state.k += pack.evicted.length;

      // 自愈路径（forced）硬丢不摘要：真实上下文已撑爆，估算不可信
      final summarizer = _summarizer;
      if (!forced && summarizer != null) {
        try {
          final capped =
              _capSummary(await summarizer.summarize(state.summary, pack.evicted));
          if (capped.isNotEmpty) state.summary = capped;
        } catch (_) {
          // 回落：保留旧摘要，移出的消息静默丢弃（与既有端侧语义一致）
        }
      }
    }

    return AssembledContext(
      messages: List.unmodifiable(pack.kept),
      summaryCard: _card(state.summary),
    );
  }

  static String? _card(String summary) =>
      summary.isEmpty ? null : '$kSummaryCardPrefix\n$summary';

  static String _capSummary(String s) {
    final t = s.trim();
    return t.length > summaryCharLimit
        ? '${t.substring(0, summaryCharLimit)}…'
        : t;
  }
}
