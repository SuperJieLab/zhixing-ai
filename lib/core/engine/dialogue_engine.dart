import 'package:socratic_ai/core/models/chat_models.dart';

/// 对话引擎抽象接口
///
/// ChatProvider 只依赖此接口，不直接依赖具体的 LLM 实现。
/// 这样做的好处：
/// - ChatProvider 可单独测试（注入 Mock 引擎）
/// - 未来换推理后端（云端 API、其他模型）只需换实现
/// - ChatProvider 不需要知道 Prompt 模板、去重策略等 LLM 专属细节
abstract class DialogueEngine {
  /// 引擎是否已就绪（模型加载完毕，可以推理）
  bool get isReady;

  /// 初始化引擎（加载模型、设置系统提示词等）
  ///
  /// 返回 true 表示初始化成功。
  Future<bool> initialize();

  /// 注入历史消息到引擎上下文（恢复对话或初始化时用）
  ///
  /// 必须在首次 [generateResponse] 之前调用。
  void seedHistory(List<ChatMessage> messages);

  /// 根据用户输入生成 AI 追问（流式返回每个字符）
  ///
  /// 外部通过 await-for 消费：
  /// ```dart
  /// await for (final token in engine.generateResponse('用户输入')) {
  ///   /* handle each token */
  /// }
  /// ```
  Stream<String> generateResponse(String userMessage);

  /// 释放引擎占用的所有资源
  void dispose();
}
