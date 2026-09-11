import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:zhixing_ai/core/data/models/chat_models.dart';

/// 摘要卡的标记前缀（双端一致；client 以一条 system 消息注入到人设之后）。
const String kSummaryCardPrefix = '【此前对话摘要】';

/// 装配结果：本次请求要发送的历史 + 可选的摘要卡。
class AssembledContext {
  /// 已过滤 + 装窗后的历史（保持原顺序，尾部为最近消息）。
  final List<ChatMessage> messages;

  /// 此前对话的滚动摘要卡（含 [kSummaryCardPrefix] 前缀，可直接作为
  /// system 消息注入）；null 表示本会话尚无摘要。
  final String? summaryCard;

  const AssembledContext({required this.messages, this.summaryCard});

  @override
  String toString() => 'AssembledContext(messages: ${messages.length}, '
      'summaryCard: ${summaryCard == null ? 'none' : '${summaryCard!.length}字'})';
}

/// 装窗结果。
class PackResult {
  /// 预算内保留的消息（尾部优先，保持原顺序）。
  final List<ChatMessage> kept;

  /// 被移出窗口的消息（恒为 [kept] 的前缀），需压缩进摘要卡。
  final List<ChatMessage> evicted;

  /// 保留窗口的估算代价（含传入的 baseCost）。
  final int used;

  const PackResult({
    required this.kept,
    required this.evicted,
    required this.used,
  });

  bool get hasEviction => evicted.isNotEmpty;

  @override
  String toString() =>
      'PackResult(kept: ${kept.length}, evicted: ${evicted.length}, used: $used)';
}

/// 上下文策略：对话历史 → 实际发送的消息。
///
/// 承载「上下文管理」职责（过滤 / 度量 / 装窗 / 压缩 / 溢出自愈契约），
/// 与「传输 / 推理后端」正交。**实现不得引用任何后端专属概念**
/// （如端侧的 nCtx、llama、LlamaDecodeException）。
abstract class ContextPolicy {
  /// 装配本次请求上下文。超预算时内部执行压缩（可能触发 [ConversationSummarizer]）。
  ///
  /// [systemPrompt] 仅参与**预算核算**（人设与摘要卡占用同一预算），
  /// 不由本策略注入——人设的唯一出处仍是 `ConversationStrategy`，
  /// 由 client 负责排列在消息列表最前。
  Future<AssembledContext> assemble(
    List<ChatMessage> history, {
    String systemPrompt = '',
  });

  /// 传输层溢出自愈钩子（如端侧 context full）：请求强制收缩，下次装配生效。
  Future<void> handleOverflow();
}

/// 度量能力（策略位）：把消息 / 文本换算成预算单位。
///
/// 单位由实现决定——端侧为 token（模板规则精确估算），
/// 云端可用字符数近似（各厂商 tokenizer 不同，粗粒度是诚实的选择）。
///
/// 实现请用 `extends`（继承 [estimateMessages] 的默认累加），
/// 只有需要更快的批量估算时才覆写它。
abstract class ContextEstimator {
  /// 单条消息的代价（含该后端特有的模板包装开销）。
  int estimateMessage(ChatMessage message);

  /// 一段纯文本的代价（system 提示词 / 摘要卡）。
  int estimateText(String text);

  /// 一组消息的代价；默认逐条累加。
  int estimateMessages(List<ChatMessage> messages) =>
      messages.fold(0, (sum, m) => sum + estimateMessage(m));
}

/// 摘要能力（策略位）：把被移出的消息与旧摘要压成新的摘要正文。
abstract class ConversationSummarizer {
  /// [previousSummary] 为旧摘要正文（首次为空串）；[evicted] 为新移出窗口的消息。
  Future<String> summarize(String previousSummary, List<ChatMessage> evicted);
}

// ─── 共享算法（① 过滤 / ③ 装窗：双端同一段代码）───

/// 过滤：剔除无资格进上下文的消息（第 0 轮欢迎语）。
///
/// 欢迎语是客户端展示用的开场白，不属于对话上下文；双端共享同一实现
/// （此前云端过滤、本地隐式全量，是同一逻辑的两处实现）。
List<ChatMessage> filterEligible(List<ChatMessage> history) =>
    history.where((m) => m.round != 0).toList();

/// 尾部优先装窗：从最后一条往前累加，直到超出 [budget] 为止。
///
/// 至少保证 [minKeep] 条最近消息留在窗口内——当前问题原文不能只存在于
/// 摘要卡里，否则模型看不到本轮问题。
///
/// [baseCost] 为窗口外的已占用预算（system 提示词 + 摘要卡）。
/// 返回的 [PackResult.evicted] 恒为 `kept` 的前缀。
PackResult packTailWithinBudget(
  List<ChatMessage> eligible, {
  required int budget,
  required ContextEstimator estimator,
  int baseCost = 0,
  int minKeep = 2,
}) {
  var cut = eligible.length;
  var used = baseCost;
  var keptCount = 0;
  while (cut > 0) {
    final cost = estimator.estimateMessage(eligible[cut - 1]);
    if (keptCount >= minKeep && used + cost > budget) break;
    used += cost;
    keptCount++;
    cut--;
  }
  return PackResult(
    kept: eligible.sublist(cut),
    evicted: eligible.sublist(0, cut),
    used: used,
  );
}

/// 强制保留最后 [keep] 条（溢出自愈路径）。
///
/// 真实上下文已撑爆时估算不可信，只做硬性收缩：不按预算衡量、
/// 也不触发摘要（内容直接丢弃），保证保留条数**真的减少**。
PackResult packKeepLast(
  List<ChatMessage> eligible, {
  required int keep,
  required ContextEstimator estimator,
  int baseCost = 0,
}) {
  final cut = eligible.length > keep ? eligible.length - keep : 0;
  final kept = eligible.sublist(cut);
  return PackResult(
    kept: kept,
    evicted: eligible.sublist(0, cut),
    used: baseCost + estimator.estimateMessages(kept),
  );
}

/// 共享装配骨架：过滤 → 装窗 → 必要时压缩成摘要卡。
///
/// 双端差异**全部**通过构造注入，本类内部不含任何分支化的后端概念：
/// - 度量单位 → [estimator]（策略位②）
/// - 预算大小 → [budget]（本地为物理硬上限，云端可设得远大于需求）
/// - 摘要实现 → [summarizer]（策略位④；null = 无摘要能力，移出即丢弃）
/// - 保底条数 → [minKeep]；溢出收缩 → [overflowKeep]（null = 不收缩）
abstract class BaseContextPolicy implements ContextPolicy {
  BaseContextPolicy({
    required ContextEstimator estimator,
    required int budget,
    ConversationSummarizer? summarizer,
    this.minKeep = 2,
    this.overflowKeep,
  })  : _estimator = estimator, // ignore: prefer_initializing_formals
        _budget = budget, // ignore: prefer_initializing_formals
        _summarizer = summarizer; // ignore: prefer_initializing_formals

  final ContextEstimator _estimator;
  final int _budget;
  final ConversationSummarizer? _summarizer;

  /// 装窗保底条数（最近消息，不因预算不足被移出）。
  final int minKeep;

  /// 溢出自愈时强制保留的条数；null = 不收缩（仅保留契约对称）。
  final int? overflowKeep;

  /// 摘要正文长度上限（超出截断，与端侧摘要口径一致）。
  static const summaryCharLimit = 200;

  /// 滚动摘要正文（会话态，随对话生命周期）。
  String _summary = '';

  /// 已被折叠进 [_summary] 的 eligible 前缀长度（避免重复摘要）。
  int _summarizedUpto = 0;

  /// 待执行的强制收缩条数（[handleOverflow] 置位，下次 [assemble] 生效）。
  int? _pendingForceKeep;

  /// 当前摘要正文（观测用）。
  @visibleForTesting
  String get summary => _summary;

  @override
  Future<AssembledContext> assemble(
    List<ChatMessage> history, {
    String systemPrompt = '',
  }) async {
    final eligible = filterEligible(history);

    // 预算核算：人设与上轮摘要卡都要占位
    var baseCost =
        systemPrompt.isEmpty ? 0 : _estimator.estimateText(systemPrompt);
    final prevCard = _card(_summary);
    if (prevCard != null) baseCost += _estimator.estimateText(prevCard);

    final forceKeep = _pendingForceKeep;
    _pendingForceKeep = null;
    final forced = forceKeep != null;

    final pack = forced
        ? packKeepLast(eligible,
            keep: forceKeep, estimator: _estimator, baseCost: baseCost)
        : packTailWithinBudget(
            eligible,
            budget: _budget,
            estimator: _estimator,
            baseCost: baseCost,
            minKeep: minKeep,
          );

    if (forced) {
      // 自愈路径：硬丢不摘要（估算已不可信），仅推进游标
      _summarizedUpto = pack.evicted.length;
    } else if (pack.evicted.length > _summarizedUpto) {
      final newlyEvicted = pack.evicted.sublist(_summarizedUpto);
      _summarizedUpto = pack.evicted.length;
      final summarizer = _summarizer;
      if (summarizer != null && newlyEvicted.isNotEmpty) {
        try {
          final capped = _capSummary(
              await summarizer.summarize(_summary, newlyEvicted));
          if (capped.isNotEmpty) _summary = capped;
        } catch (_) {
          // 回落：保留旧摘要，新移出的消息静默丢弃（与既有本地语义一致）
        }
      }
    }

    return AssembledContext(
      messages: pack.kept,
      summaryCard: _card(_summary),
    );
  }

  @override
  Future<void> handleOverflow() async {
    // null → 无收缩（契约对称，云端策略如此）；非 null → 下次装配硬收缩
    _pendingForceKeep = overflowKeep;
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
