import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/chat/chat_page.dart';
import 'package:socratic_ai/features/topics/providers/topic_provider.dart';
import 'package:socratic_ai/features/topics/topic_selection_page.dart';

/// TopicSelectionPage 输入验证测试
///
/// 验证自定义话题输入框的验证逻辑：
/// 1. 空内容/纯空格提交 → 显示 SnackBar 提示
/// 2. 有效话题提交 → 导航到 ChatPage
void main() {
  /// 构建带有 TopicProvider 的测试 Widget
  ///
  /// ChatPage 内部直接使用 ConversationService（不再依赖 Provider 注入），
  /// 因此测试中不需要提供 ConversationProvider。
  Widget buildTestApp() {
    return MaterialApp(
      theme: AppTheme.lightTheme,
      home: ChangeNotifierProvider(
        create: (_) => TopicProvider(),
        child: const TopicSelectionPage(),
      ),
    );
  }

  group('TopicSelectionPage 输入验证', () {
    testWidgets('空内容提交时显示 SnackBar 提示', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      // 滚动到输入框可见
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pump();

      final textField = find.byType(TextField);
      expect(textField, findsOneWidget);

      // 提交空内容
      await tester.enterText(textField, '');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      // 应显示 SnackBar
      expect(find.text('请输入话题内容'), findsOneWidget);
    });

    testWidgets('纯空格提交时显示 SnackBar 提示', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      // 滚动到输入框可见
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pump();

      final textField = find.byType(TextField);
      expect(textField, findsOneWidget);

      // 提交纯空格
      await tester.enterText(textField, '   ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      // 应显示 SnackBar（trim 后为空字符串）
      expect(find.text('请输入话题内容'), findsOneWidget);
    });

    testWidgets('有效话题提交后导航到 ChatPage', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      // 滚动到输入框可见
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pump();

      final textField = find.byType(TextField);
      expect(textField, findsOneWidget);

      // 提交有效话题
      await tester.enterText(textField, '有效话题');
      await tester.testTextInput.receiveAction(TextInputAction.done);

      // 使用 pump() 而非 pumpAndSettle()，因为 ChatPage
      // 在模型加载阶段会显示 CircularProgressIndicator（无限动画），
      // pumpAndSettle 会导致超时。只泵一帧即可验证导航已触发。
      await tester.pump();

      // 导航后应显示 ChatPage（可能在 loading 或 error 状态）
      expect(find.byType(ChatPage), findsOneWidget);
      // 不应显示 SnackBar
      expect(find.text('请输入话题内容'), findsNothing);

      // ChatPage 的 AppBar 在所有状态下都会显示话题标题
      expect(find.text('有效话题'), findsOneWidget);
    });
  });
}
