import 'package:socratic_ai/core/models/chat_models.dart';

/// 将对话历史格式化为纯文本（供 Extractor 组装 LLM 输入用）
String buildConversationText(String topic, List<ChatMessage> conversation) {
  final buffer = StringBuffer();
  buffer.writeln('话题：$topic\n');
  for (final msg in conversation) {
    final role = msg.role == MessageRole.ai ? 'AI' : '用户';
    buffer.writeln('$role：${msg.content}');
  }
  return buffer.toString();
}
