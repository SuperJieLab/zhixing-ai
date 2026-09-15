import 'package:zhixing_ai/core/data/models/chat_models.dart';

/// 上下文预算原语（context 域共享层）：度量接口、装箱算法。
///
/// 红线：本文件**不得**依赖任何 feature，也**不得**出现任何后端专属概念
/// （nCtx / llama / BYOK）；度量单位由实现决定（token / 字符都是合法单位），
/// 算法只面对 [ContextEstimator] 抽象。端侧 token 度量实现见
/// `core/llm/engine/llama_template_estimator.dart`（由门面注入）。
///
/// 从 `features/chat/engine/context/context_policy.dart` 平移（Task 1 原语下沉，
/// 零行为变更）。

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

  @override
  String toString() =>
      'PackResult(kept: ${kept.length}, evicted: ${evicted.length}, used: $used)';
}

/// 尾部优先装窗：从最后一条往前累加，直到超出 [budget] 为止。
///
/// 至少保证 [minKeep] 条最近消息留在窗口内——当前问题原文不能只存在于
/// 摘要卡里，否则模型看不到本轮问题。非对话场景（如单次提取）可传
/// `minKeep: 0` 关闭保底，退化为纯粹的预算截断。
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
