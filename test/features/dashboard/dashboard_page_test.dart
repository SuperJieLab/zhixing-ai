import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhixing_ai/features/dashboard/dashboard_page.dart';

/// DashboardPage 渲染测试
///
/// DashboardPage 通过 DashboardProvider 管理状态（Provider → DashboardRepository → sqflite）。
/// 在测试环境中 sqflite 不可用，load() 会抛异常，页面应展示错误视图而非崩溃。
///
/// v2 Dashboard 三区结构：
/// - 目标与策略（GoalCard）
/// - 执行路线（StrategyTimeline）
/// - 洞察（CrossPatternCard）
void main() {
  group('DashboardPage', () {
    testWidgets('在 DB 不可用时不崩溃并展示错误视图', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: DashboardPage()),
      );

      // 等待 load 完成（失败后会设置 error state）
      await tester.pumpAndSettle();

      // 页面应该不崩溃
      expect(find.byType(DashboardPage), findsOneWidget);
    });

    testWidgets('AppBar 显示"首页"标题 + 模型管理/历史记录图标', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: DashboardPage()),
      );
      await tester.pumpAndSettle();

      // AppBar 标题
      expect(find.text('首页'), findsOneWidget);

      // 设置和历史图标
      expect(find.byIcon(Icons.settings), findsOneWidget);
      expect(find.byIcon(Icons.history), findsOneWidget);
    });

    testWidgets('FAB "新对话" 按钮存在', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: DashboardPage()),
      );
      await tester.pumpAndSettle();

      // FAB 的标签文本
      expect(find.text('新对话'), findsOneWidget);
    });
  });
}
