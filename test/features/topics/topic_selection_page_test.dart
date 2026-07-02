import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:socratic_ai/features/topics/providers/topic_provider.dart';
import 'package:socratic_ai/features/topics/topic_selection_page.dart';

/// TopicSelectionPage 的 Widget 测试
///
/// 测试重点：
/// 1. 5 个预设话题卡片是否全部渲染
/// 2. 自定义输入框是否存在
///
/// ## ChangeNotifierProvider 在测试中的用法
/// 因为 TopicSelectionPage 内部通过 context.watch<TopicProvider>()
/// 获取状态，所以测试时需要用 ChangeNotifierProvider 包裹它，
/// 提供 TopicProvider 实例。
void main() {
  // ============================================================
  // 测试 1：5 个预设话题全部可见
  // ============================================================
  testWidgets('TopicSelectionPage 显示全部 5 个预设话题', (tester) async {
    // 用 ChangeNotifierProvider 包裹页面，提供 TopicProvider
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => TopicProvider(), // 新建一个 Provider 实例
        child: const MaterialApp(home: TopicSelectionPage()),
      ),
    );

    // 断言：5 个话题标题都出现在了页面上
    expect(find.text('职业发展'), findsOneWidget);
    expect(find.text('两难决策'), findsOneWidget);
    expect(find.text('自我探索'), findsOneWidget);
    expect(find.text('工作难题'), findsOneWidget);
    expect(find.text('人际关系'), findsOneWidget);
  });

  // ============================================================
  // 测试 2：自定义输入框存在
  // ============================================================
  testWidgets('TopicSelectionPage 包含自定义话题输入框', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => TopicProvider(),
        child: const MaterialApp(home: TopicSelectionPage()),
      ),
    );

    // TextField 在 ListView 底部，默认不显示在初始视口内
    // 需要先向下滚动才能找到
    // drag = 模拟手指在屏幕上向上滑动（Offset dx: 0, dy: -300）
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    // pump 等一帧让滚动生效
    await tester.pump();

    // 现在 TextField 应该可见了
    expect(find.byType(TextField), findsOneWidget);
  });
}
