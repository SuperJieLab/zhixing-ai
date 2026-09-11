import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;
import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/llm/llama_service.dart';
import 'package:zhixing_ai/core/llm/think_tag_stripper.dart';
import 'package:zhixing_ai/features/chat/engine/context_policy.dart';
import 'package:zhixing_ai/features/chat/engine/conversation_strategy.dart';

/// 端侧度量（策略位②）：token 估算 + 每条消息的 chat template 包装开销。
///
/// 端侧能精确估算是因为我们掌握 llama.cpp 的模板渲染规则；
/// 云端不具备这个前提，故两端的度量单位由各自实现决定。
class LlamaTemplateEstimator extends ContextEstimator {
  /// 每条消息的 template 包装开销（角色标记等），逐条累加。
  static const perMessageOverhead = 16;

  @override
  int estimateMessage(ChatMessage message) =>
      LlamaService.estimateTokens(message.content) + perMessageOverhead;

  @override
  int estimateText(String text) => LlamaService.estimateTokens(text);
}

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
    try {
      chat.addSystem(ConversationStrategy.buildSummaryPrompt(
        previousSummary: previousSummary,
        dropped: evicted
            .map((m) => (role: m.role.name, content: m.content))
            .toList(),
      ));
      chat.addUser('请输出摘要。');
      final buf = StringBuffer();
      await for (final event in chat.generate(
        sampler: const SamplerParams(temperature: 0.3),
        maxTokens: 512,
      )) {
        if (event is TokenEvent) buf.write(event.text);
      }
      return stripThinkTags(buf.toString());
    } finally {
      chat.dispose();
    }
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
