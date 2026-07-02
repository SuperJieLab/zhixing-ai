import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:socratic_ai/core/constants.dart';
import 'package:socratic_ai/features/topics/widgets/topic_card.dart';

/// TopicCard 组件的 Widget 测试
///
/// 和之前的 Provider 单元测试不同，这里是 **Widget 测试**：
/// - 会真实渲染 Widget（在虚拟屏幕上）
/// - 可以模拟点击、滑动等用户操作
/// - testWidgets() 是入口函数，tester 是操作 Widget 的工具
///
/// ## pumpWidget vs pump
/// - pumpWidget(widget)：把 Widget 挂到虚拟 Widget 树上
/// - tester.pump()：等一帧（让动画、状态更新生效）
void main() {
  // ============================================================
  // 测试 1：TopicCard 能正确显示图标、标题和描述
  // ============================================================
  testWidgets('TopicCard 显示图标、标题和描述文字', (tester) async {
    // 准备：创建一个测试用的 TopicItem
    const topic = TopicItem(
      icon: '🧭',
      title: '职业发展',
      description: '该深耕还是该转型？',
    );

    // 渲染：把 TopicCard 放进 MaterialApp 和 Scaffold 里渲染
    // MaterialApp 提供主题上下文，Scaffold 提供布局约束
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: TopicCard(topic: topic)),
      ),
    );

    // 断言 1：页面上出现了 emoji 图标 '🧭'
    expect(find.text('🧭'), findsOneWidget);

    // 断言 2：页面上出现了标题 '职业发展'
    expect(find.text('职业发展'), findsOneWidget);

    // 断言 3：页面上出现了描述 '该深耕还是该转型？'
    expect(find.text('该深耕还是该转型？'), findsOneWidget);
  });

  // ============================================================
  // 测试 2：点击卡片后，onTap 回调被触发
  // ============================================================
  testWidgets('点击 TopicCard 后，onTap 回调被触发', (tester) async {
    const topic = TopicItem(
      icon: '🧭',
      title: '职业发展',
      description: 'test',
    );

    // 用变量记录 onTap 被调用时传入了什么
    String? tappedTitle;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TopicCard(
            topic: topic,
            // 当用户点击卡片时，把标题存到 tappedTitle
            onTap: (t) => tappedTitle = t.title,
          ),
        ),
      ),
    );

    // 模拟：点击卡片上显示 '职业发展' 文字的区域
    await tester.tap(find.text('职业发展'));

    // 断言：onTap 被调用了，且传入的标题是 '职业发展'
    expect(tappedTitle, '职业发展');
  });
}
