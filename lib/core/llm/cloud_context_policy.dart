import 'package:dio/dio.dart';
import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/llm/cloud_completion.dart';
import 'package:zhixing_ai/core/llm/context_assembly.dart';
import 'package:zhixing_ai/core/llm/context_budget.dart';
import 'package:zhixing_ai/core/llm/summary_prompt.dart';
import 'package:zhixing_ai/core/llm/think_tag_stripper.dart';

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

/// 云端摘要器（策略位④）：复用同一 BYOK 端点，**非流式**小请求。
///
/// 端侧摘要走本地 2B 模型（零成本、离线，但质量有限）；云端既然已经付费，
/// 摘要就直接用同一个云端模型做——这是「能力对等、策略不同」中
/// 「摘要器实现不同」的直接体现。
///
/// 请求形态与异常语义统一走 [CloudCompletion]（Task 2 抽出的共享单次补全，
/// 服务层云端 `ask` 同源）；本类只负责摘要提示词与输出上限。
/// 异常一律向上抛，由 [BaseContextPolicy] 兜底回落（保留旧摘要、
/// 被移出消息静默丢弃）。
class CloudSummarizer implements ConversationSummarizer {
  /// 摘要请求的输出上限：摘要目标 ≤200 字，512 足够且省钱。
  static const int maxTokens = 512;

  final CloudCompletion _completion;

  /// [dio] 仅测试注入；生产用 [baseUrl] 自建。
  CloudSummarizer({
    required String baseUrl,
    required String apiKey,
    required String modelName,
    Dio? dio,
  }) : _completion = CloudCompletion(
          baseUrl: baseUrl,
          apiKey: apiKey,
          modelName: modelName,
          dio: dio,
        );

  @override
  Future<String> summarize(
      String previousSummary, List<ChatMessage> evicted) async {
    // 提示词与端侧共用同一纯函数：摘要口径（保留什么、压缩到多少字）双端一致。
    final prompt = buildSummaryPrompt(
      previousSummary: previousSummary,
      dropped:
          evicted.map((m) => (role: m.role.name, content: m.content)).toList(),
    );

    final content = await _completion.complete(
      system: prompt,
      user: '请输出摘要。',
      maxTokens: maxTokens,
    );
    return stripThinkTags(content);
  }
}

/// 云端上下文策略（后端策略）：能力与端侧对等，差异只在度量单位与摘要器实现。
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
