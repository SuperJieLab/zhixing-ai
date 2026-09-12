import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;
import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/llm/context_assembly.dart';
import 'package:zhixing_ai/core/llm/context_budget.dart';
import 'package:zhixing_ai/core/llm/inference.dart';
import 'package:zhixing_ai/core/llm/summary_prompt.dart';

// LlamaTemplateEstimator（端侧度量，策略位②）在 `context_budget.dart`——
// 它与装箱原语同属共享层。

/// 端侧摘要器（策略位④）：一次性独立 session，不污染对话 session 上下文。
///
/// [think 标签剥离]：摘要模型同为思考模型，取闭合标签后的正文
/// （`completeText(stripThink: true)`）。
class LlamaSummarizer implements ConversationSummarizer {
  final LlamaEngine _engine;

  LlamaSummarizer(this._engine);

  @override
  Future<String> summarize(
      String previousSummary, List<ChatMessage> evicted) async {
    final chat = await _engine.createChat();
    return completeText(
      chat,
      system: buildSummaryPrompt(
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

/// 端侧上下文策略（后端策略）：度量 + 预算 + 摘要实现。
///
/// 装配算法在 [BaseContextPolicy]（无状态），会话态由调用方持有的
/// [ContextState] 承载；本类只提供端侧参数：
/// - 度量：token（模板规则精确估算，含每条 +16 包装开销）
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
