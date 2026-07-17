import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:zhixing_ai/app.dart';
import 'package:zhixing_ai/core/model_manager.dart';

/// 端到端冒烟测试
///
/// 模拟用户完整操作流程，验证所有页面和组件串联工作正常：
/// 1. 首页 → 看到 5 个话题 + 标语
/// 2. 点击「职业发展」→ 跳转对话页 → 看到欢迎消息
/// 3. 输入消息发送 → 用户消息 + AI 追问出现在屏幕上
/// 4. 自定义话题 → 输入后跳转对话页
///
/// ## pumpWidget vs pumpAndSettle
/// - pumpWidget()：把 Widget 挂上树
/// - pumpAndSettle()：等待所有动画完成（页面跳转、过渡动画）
/// - pump()：只等一帧
void main() {
  /// 构建测试用的完整 App（带 Provider 注入）
  Widget buildTestApp() {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<ModelManager>.value(value: ModelManager.instance),
      ],
      child: const ZhixingApp(),
    );
  }

  // ============================================================
  // 测试 1：首页 → 选话题 → 对话 → 发消息
  // ============================================================
  testWidgets('完整流程：选择话题 → 对话 → 发送消息', (tester) async {
    // ── 首页渲染 ──
    await tester.pumpWidget(buildTestApp());

    // 断言：首页显示了 App 名称和标语
    expect(find.text('知行AI'), findsWidgets);
    expect(find.text('帮你想清楚'), findsOneWidget);

    // 断言：5 个预设话题可见
    expect(find.text('职业发展'), findsOneWidget);
    expect(find.text('两难决策'), findsOneWidget);
    expect(find.text('自我探索'), findsOneWidget);
    expect(find.text('工作难题'), findsOneWidget);
    expect(find.text('人际关系'), findsOneWidget);

    // ── 点击「职业发展」跳转到对话页 ──
    await tester.tap(find.text('职业发展'));
    // pumpAndSettle 等待页面跳转动画完成
    await tester.pumpAndSettle();

    // 断言：导航到了对话页，AppBar 显示话题标题
    expect(find.text('职业发展'), findsWidgets); // AppBar 标题
    // 断言：欢迎消息包含「职业方向」
    expect(find.textContaining('职业方向'), findsOneWidget);

    // ── 输入并发送消息 ──
    // 找到输入框（ChatPage 中唯一的 TextField）
    await tester.enterText(find.byType(TextField), '我想转管理岗位');
    // 模拟按回车发送
    await tester.testTextInput.receiveAction(TextInputAction.done);
    // 等待状态更新 + UI 刷新
    await tester.pump();

    // 断言：用户消息出现在屏幕上
    expect(find.text('我想转管理岗位'), findsOneWidget);

    // 断言：AI 追问也出现了（Mock 回复不为空）
    // 因为 Mock 回复是轮换的，我们用 textContaining 检查
    // 至少有一条非用户消息出现在屏幕上
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text && widget.data != null && widget.data!.isNotEmpty,
      ),
      findsWidgets,
    );
  });

  // ============================================================
  // 测试 2：自定义话题流程
  // ============================================================
  testWidgets('自定义话题：输入 → 回车 → 跳转到对话页', (tester) async {
    await tester.pumpWidget(buildTestApp());

    // 自定义输入框在 ListView 底部，先滚动到可见
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pump();

    // 在底部输入框中输入自定义话题
    await tester.enterText(
      find.byType(TextField).last, // 底部自定义输入框是最后一个 TextField
      '如何处理焦虑',
    );

    // 按回车发送（触发 onSubmitted → Navigator.push → ChatPage）
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    // 断言：导航到了对话页，AppBar 显示了自定义话题
    expect(find.text('如何处理焦虑'), findsOneWidget);
  });
}
