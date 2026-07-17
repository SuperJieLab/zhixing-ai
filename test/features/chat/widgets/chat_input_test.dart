import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhixing_ai/features/chat/widgets/chat_input.dart';

/// ChatInput 组件的 Widget 测试
///
/// ChatInput 是对话页面底部的输入栏，包含：
/// - 圆角输入框（暖白底色）
/// - 圆形发送按钮（鼠尾草绿底色）
///
/// ## StatefulWidget 的特殊测试技巧
/// ChatInput 内部管理了一个 TextEditingController（有状态），
/// 所以需要用 tester.enterText() 模拟输入，
/// tester.testTextInput.receiveAction() 模拟按回车。
void main() {
  // ============================================================
  // 测试 1：输入文字后按回车，onSend 回调被触发
  // ============================================================
  testWidgets('输入文字后按回车，onSend 收到正确内容', (tester) async {
    String? submitted;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatInput(
            // 模拟发送回调：把消息存到 submitted 变量
            onSend: (msg) => submitted = msg,
          ),
        ),
      ),
    );

    // 模拟用户输入 '测试消息'
    await tester.enterText(find.byType(TextField), '测试消息');

    // 模拟用户按键盘上的「发送/完成」键
    await tester.testTextInput.receiveAction(TextInputAction.done);

    // 断言：onSend 被调用，且收到的消息内容正确
    expect(submitted, '测试消息');
  });

  // ============================================================
  // 测试 2：发送后输入框被清空
  // ============================================================
  testWidgets('发送消息后输入框被清空', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ChatInput()),
      ),
    );

    // 输入文字
    await tester.enterText(find.byType(TextField), '测试');

    // 按回车发送
    await tester.testTextInput.receiveAction(TextInputAction.done);

    // 等待一帧让状态生效
    await tester.pump();

    // 断言：输入框里已经没有 '测试' 了
    expect(find.text('测试'), findsNothing);
  });

  // ============================================================
  // 测试 3：空消息不会触发 onSend
  // ============================================================
  testWidgets('空消息不会触发 onSend 回调', (tester) async {
    bool wasCalled = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatInput(
            onSend: (_) => wasCalled = true,
          ),
        ),
      ),
    );

    // 直接按回车（没有输入内容）
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    // 断言：onSend 没有被调用
    expect(wasCalled, false);
  });
}
