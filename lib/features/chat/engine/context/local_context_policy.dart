import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;
import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/llm/inference.dart';
import 'package:zhixing_ai/features/chat/engine/context/context_policy.dart';
import 'package:zhixing_ai/features/chat/engine/prompt/conversation_strategy.dart';

// LlamaTemplateEstimator 已下沉 `core/llm/context_budget.dart`（Task 1），
// 经上方 context_policy.dart 的 re-export 继续可见。

/// 端侧摘要器（策略位④）：一次性独立 session，不污染对话 session 上下文。
///
/// [think 标签剥离]：摘要模型同为思考模型，取闭合标签后的正文。
class LlamaSummarizer implements ConversationSummarizer {
  final LlamaEngine _engine;

  LlamaSummarizer(this._engine);

  @override
  Future<String> summarize(
      String previousSummary, List<ChatMessage> evicted) async {
    final chat = await _engine.createChat();
    return completeText(
      chat,
      system: ConversationStrategy.buildSummaryPrompt(
        previousSummary: previousSummary,
        dropped: evicted
            .map((m) => (role: m.role.name, content: m.content))
            .toList(),
      ),
      user: '请输出摘要。',
      sampler: const SamplerParams(temperature: 0.3),
      maxTokens: 512,
      stripThink: true,
    );
  }
}

/// 端侧上下文策略：能力与云端对等，差异只在度量单位与摘要器实现。
///
/// - 预算 = `nCtx − 生成上限 − 余量`（端侧物理硬上限）
/// - 溢出（context full）自愈：硬留最后 4 条，保证保留内容真的减少
class LocalContextPolicy extends BaseContextPolicy {
  LocalContextPolicy({super.summarizer, int? budget})
      : super(
          estimator: LlamaTemplateEstimator(),
          budget: budget ?? AppConstants.localInputBudget,
          minKeep: 2,
          overflowKeep: 4,
        );
}
