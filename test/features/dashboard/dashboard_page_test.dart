import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:zhixing_ai/core/platform/sync_service.dart';
import 'package:zhixing_ai/features/dashboard/dashboard_page.dart';

/// DashboardPage 渲染测试
///
/// DashboardPage 通过 DashboardProvider 管理状态（Provider → DashboardRepository → sqflite）。
/// 在测试环境中 sqflite 不可用，load() 会抛异常，页面应落到错误视图而非崩溃。
/// 页面依赖的共享服务（SyncService）由 composition root 提供，测试补最小 Provider 树。
///
/// 只保留「失败路径不崩 + 落到错误视图」这一条：纯存在性断言（AppBar 标题、
/// FAB 文案）对回归没有保护力，交给人工/集成验证。
Widget _app() => Provider<SyncService>.value(
      value: SyncService(),
      child: const MaterialApp(home: DashboardPage()),
    );

void main() {
  group('DashboardPage', () {
    testWidgets('DB 不可用：不崩溃并落到错误视图', (tester) async {
      await tester.pumpWidget(_app());

      // 等待 load 完成（失败后会设置 error state）
      await tester.pumpAndSettle();

      expect(find.byType(DashboardPage), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });
  });
}
