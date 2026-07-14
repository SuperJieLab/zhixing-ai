import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:socratic_ai/features/chat/chat_page.dart';

/// ChatPage 的 Widget 测试
///
/// ChatPage 是整个对话功能的核心页面，集成：
/// - ChatBubble（消息列表）
/// - ChatInput（底部输入栏）
/// - 顶部导航栏（话题标题 + 轮次显示 + 结束对话按钮）
///
/// ## Provider 注入
/// ChatPage 内部会创建自己的 ChatProvider，
/// 所以测试中需要用 ChangeNotifierProvider 包裹。
void main() {
  /// 构建测试用的 ChatPage
  ///
  /// 封装成函数避免每次写重复的 Provider 包裹代码。
  Widget buildTestWidget({String topic = '职业发展'}) {
    return MaterialApp(home: ChatPage(topic: topic));
  }

  // ============================================================
  // 测试 1：话题标题显示在 AppBar 中
  // ============================================================
  testWidgets('ChatPage 在 AppBar 中显示话题标题', (tester) async {
    await tester.pumpWidget(buildTestWidget());
    expect(find.text('职业发展'), findsOneWidget);
  });

  // ============================================================
  // 测试 2：初始状态显示 AI 欢迎消息
  // ============================================================
  testWidgets('ChatPage 初始显示 AI 欢迎消息', (tester) async {
    await tester.pumpWidget(buildTestWidget());

    // 欢迎消息中包含 '职业方向' 关键词
    // 注意：使用 findsWidgets（至少找一个），因为 AppBar 的标题也包含「职业」
    expect(find.textContaining('职业方向'), findsOneWidget);
  });

  // ============================================================
  // 测试 3：页面包含输入框
  // ============================================================
  testWidgets('ChatPage 包含输入框', (tester) async {
    await tester.pumpWidget(buildTestWidget());

    // 应该有 TextField（ChatInput 组件里有一个）
    expect(find.byType(TextField), findsOneWidget);
  });
}
