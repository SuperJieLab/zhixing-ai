import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/context/context_budget.dart';
import 'package:zhixing_ai/core/context/context_state.dart';

/// 转换段（context 域）：对话历史 + 会话压缩状态 → 本次请求实际要发送的上下文。
///
/// 从 `features/chat/engine/context/context_policy.dart` 上移 + **状态外置**
/// （2026-09-12 设计 §10.1 #4 拍定 A）：装配算法无状态，会话态由调用方持有的
/// [ContextState] 实例承载——v2 起**实例由 ModelGateway 私有持有**。
///
/// 本域红线：不得出现任何后端专属概念（nCtx / llama / BYOK）；双端差异
/// 全部经构造参数注入（度量 / 预算 / 摘要器 / 保底 / 溢出收缩）。

/// [ContextState] 独立成文件；此处再导出保持单一 import 面。
export 'package:zhixing_ai/core/context/context_state.dart';

/// 摘要卡的标记前缀（双端一致；交付实现以一条 system 消息注入到人设之后）。
const String kSummaryCardPrefix = '【此前对话摘要】';

/// 入口截断标记前缀（业界通行做法，如 Claude Code 的 `[... truncated]`）：
/// 当前问题本身超预算被截断时，加在保留内容头部，显式告知模型「看到的不是全部」，
/// 防止把残缺内容当完整事实作答。
const String kInputTruncatedPrefix = '……[前文过长已截断]\n';

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

/// 入口截断：当前问题（尾部用户消息）自身就超预算时的唯一出路。
///
/// 历史超预算可以挤旧消息，但**当前问题不能丢**（丢了模型无从回答），
/// 溢出自愈的收缩粒度是「条」、对它也无能为力——不截断就会陷入
/// 「每轮爆窗 → 自愈无效 → 永远兜底文案」的死循环。业界通行做法是
/// 摄入时截断 + 显式标记（Claude Code / Cline 均如此）：保留尾部
/// （用户最新意图在末尾，背景由摘要卡承载），头部加 [kInputTruncatedPrefix]。
extension _PackEntryTruncation on PackResult {
  PackResult truncateOversizeTail({
    required int budget,
    required ContextEstimator estimator,
    required int baseCost,
  }) {
    if (kept.isEmpty) return this;
    final tail = kept.last;
    if (tail.role != MessageRole.user) return this;

    final tailCost = estimator.estimateMessage(tail);
    final othersCost = estimator.estimateMessages(kept) - tailCost;
    final allowed = budget - baseCost - othersCost;
    if (tailCost <= allowed) return this;

    final contentBudget =
        allowed - (tailCost - estimator.estimateText(tail.content));
    final tailText = _tailWithinCost(
      tail.content,
      maxCost: contentBudget > 0 ? contentBudget : 0,
      estimator: estimator,
    );
    final replaced = ChatMessage(
      role: tail.role,
      content: '$kInputTruncatedPrefix$tailText',
      round: tail.round,
    );
    return PackResult(
      kept: [...kept.sublist(0, kept.length - 1), replaced],
      evicted: evicted,
      used: baseCost + othersCost + estimator.estimateMessage(replaced),
    );
  }

  /// 取文本的尾部片段，使估算代价 ≤ [maxCost]（二分起点 + 前向校准兜底
  /// 估算的类间非线性）。[maxCost] ≤ 0 返回空串（至少不塞爆窗口）。
  static String _tailWithinCost(
    String content, {
    required int maxCost,
    required ContextEstimator estimator,
  }) {
    if (maxCost <= 0) return '';
    if (estimator.estimateText(content) <= maxCost) return content;
    var lo = 0;
    var hi = content.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (estimator.estimateText(content.substring(mid)) > maxCost) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    while (lo > 0 &&
        lo < content.length &&
        estimator.estimateText(content.substring(lo)) > maxCost) {
      lo++;
    }
    return content.substring(lo);
  }
}

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

    final pack = (forced
            ? _packOverflowHeal(window,
                keep: forceKeep,
                budget: budget,
                estimator: _estimator,
                baseCost: baseCost)
            : packTailWithinBudget(
                window,
                budget: budget,
                estimator: _estimator,
                baseCost: baseCost,
                minKeep: minKeep,
              ))
        // 入口截断：两条路径共用（正常装窗 + 自愈收缩），单条超预算在这里收口
        .truncateOversizeTail(
            budget: budget, estimator: _estimator, baseCost: baseCost);

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

  /// 溢出自愈装箱：从 [keep] 条起硬收缩，**仍超预算则继续减条，保底 1 条**。
  ///
  /// 真实上下文已撑爆时估算不可信，收缩本身就是对估算的纠偏——但一条长
  /// 回复即可超过整个输入预算（如一条 2048 token 的回复 vs 1664 token 的
  /// 输入预算），固定条数会陷入「收缩后下轮再爆」的循环；预算内再收一层，
  /// 才能保证保留内容真的减到引擎能吃下。
  static PackResult _packOverflowHeal(
    List<ChatMessage> window, {
    required int keep,
    required int budget,
    required ContextEstimator estimator,
    required int baseCost,
  }) {
    var effective = window.length < keep ? window.length : keep;
    while (effective > 1) {
      final kept = window.sublist(window.length - effective);
      if (baseCost + estimator.estimateMessages(kept) <= budget) break;
      effective--;
    }
    return packKeepLast(window, keep: effective, estimator: estimator);
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
