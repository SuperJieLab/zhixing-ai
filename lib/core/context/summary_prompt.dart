/// 上下文压缩摘要提示词（基本建默认，双端共用）。
///
/// 从 `features/chat/engine/prompt/conversation_strategy.dart` 上移（Task 3）：
/// 摘要口径属**模型能力差异**而非业务差异，故归基建；覆盖点是 **App 级单一**
/// （若要按模型能力分档，在此函数加参数，不按 feature 各写一份）。
///
/// [previousSummary] 非空表示递归压实（旧摘要与新增对话合并为新摘要）。
/// 调用方式：system = 本提示词，user = '请输出摘要。' 触发一次补全。
String buildSummaryPrompt({
  String previousSummary = '',
  required List<({String role, String content})> dropped,
}) {
  final old = previousSummary.isEmpty
      ? ''
      : '【此前摘要】\n$previousSummary\n\n请把它与下面的对话合并为一份新摘要。\n';
  final dialogue = dropped
      .where((m) => m.content.isNotEmpty)
      .map((m) => '${m.role == 'user' ? '用户' : '助手'}: ${m.content}')
      .join('\n');
  return '''你是对话摘要器。请把给定的对话内容压缩成不超过 200 字的一段摘要，作为后续对话的背景资料。
要求：
- 保留：用户的目标与偏好、对话中确认的事实、尚未解决的问题
- 写成连贯的一段话，不复述对话原文，不逐条罗列
- 直接输出摘要正文，不要任何前言、解释或标记
$old
【待压缩对话】
$dialogue''';
}
