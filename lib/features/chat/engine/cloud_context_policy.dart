import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/features/chat/engine/cloud_summarizer.dart';
import 'package:zhixing_ai/features/chat/engine/context_policy.dart';

/// 云端度量（策略位②）：字符数近似。
///
/// 各厂商 tokenizer 不同、本地没有可用的精确分词器，故如实取**字符数**作为
/// 粗粒度预算单位，不假装精确（相对误差由预算余量吸收，量级正确即可）。
class CharCountEstimator extends ContextEstimator {
  /// 每条消息的角色标记与 JSON 包装开销（粗估，逐条累加）。
  static const perMessageOverhead = 16;

  @override
  int estimateMessage(ChatMessage message) =>
      message.content.length + perMessageOverhead;

  @override
  int estimateText(String text) => text.length;
}

/// 云端上下文策略：能力与端侧对等，差异只在度量单位与摘要器实现。
///
/// - 度量：字符数近似（[CharCountEstimator]）
/// - 预算：[AppConstants.cloudInputBudget]，远大于常见对话长度 → 实践中
///   基本不触发装窗/摘要，机制完整保留作超长对话兜底
/// - 摘要：云端模型（[CloudSummarizer]，同一个 BYOK 端点）
/// - 溢出：无收缩（`overflowKeep = null`）——云端不存在本地 context full
///   这类物理硬上限，[BaseContextPolicy] 的空实现已满足契约对称
class CloudContextPolicy extends BaseContextPolicy {
  CloudContextPolicy({
    required String baseUrl,
    required String apiKey,
    required String modelName,
    int? budget,
    ConversationSummarizer? summarizer,
  }) : super(
          estimator: CharCountEstimator(),
          budget: budget ?? AppConstants.cloudInputBudget,
          summarizer: summarizer ??
              CloudSummarizer(
                baseUrl: baseUrl,
                apiKey: apiKey,
                modelName: modelName,
              ),
          minKeep: 2,
          overflowKeep: null,
        );
}
