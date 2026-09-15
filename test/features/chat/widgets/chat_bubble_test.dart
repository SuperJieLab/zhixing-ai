import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/features/chat/widgets/chat_bubble.dart';

/// ChatBubble 组件的 Widget 测试
///
/// ChatBubble 根据消息角色（AI 还是用户）调整对齐方向和颜色：
/// - AI（左对齐、白色背景）：像对方在说话，内容经 MarkdownMessageView 渲染
/// - 用户（右对齐、绿色背景）：像自己发出的消息，纯文本
void main() {
  // 两种角色的内容渲染差异（AI 走 Markdown → 文字在 RichText 内，
  // 须 findRichText: true；用户为纯文本）——合并为一个用例，避免重复的
  // 「存在即通过」断言。
  testWidgets('按角色渲染消息内容：AI 走 Markdown、用户为纯文本', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatBubble(
            message: ChatMessage(
              role: MessageRole.ai,
              content: '你好，你想聊什么？',
              round: 1,
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('你好，你想聊什么？', findRichText: true),
        findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatBubble(
            message: ChatMessage(
              role: MessageRole.user,
              content: '我想聊聊职业发展',
              round: 1,
            ),
          ),
        ),
      ),
    );
    expect(find.text('我想聊聊职业发展'), findsOneWidget);
  });
}
