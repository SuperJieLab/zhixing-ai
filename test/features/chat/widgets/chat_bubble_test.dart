import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhixing_ai/core/models/chat_models.dart';
import 'package:zhixing_ai/features/chat/widgets/chat_bubble.dart';

/// ChatBubble 组件的 Widget 测试
///
/// ChatBubble 根据消息角色（AI 还是用户）调整对齐方向和颜色：
/// - AI（左对齐、白色背景）：像对方在说话
/// - 用户（右对齐、绿色背景）：像自己发出的消息
///
/// 这是微信/Telegram 等聊天应用的通用 UI 模式。
void main() {
  // ============================================================
  // 测试 1：AI 消息的气泡应显示内容
  // ============================================================
  testWidgets('AI 消息的气泡正确显示文字内容', (tester) async {
    // 准备：一条 AI 发出的欢迎消息
    const msg = ChatMessage(
      role: MessageRole.ai,
      content: '你好，你想聊什么？',
      round: 1,
    );

    // 渲染
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ChatBubble(message: msg)),
      ),
    );

    // 断言：消息文字可见
    expect(find.text('你好，你想聊什么？'), findsOneWidget);
  });

  // ============================================================
  // 测试 2：用户消息的气泡应显示内容
  // ============================================================
  testWidgets('用户消息的气泡正确显示文字内容', (tester) async {
    // 准备：一条用户发出的消息
    const msg = ChatMessage(
      role: MessageRole.user,
      content: '我想聊聊职业发展',
      round: 1,
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ChatBubble(message: msg)),
      ),
    );

    // 断言：消息文字可见
    expect(find.text('我想聊聊职业发展'), findsOneWidget);
  });
}
