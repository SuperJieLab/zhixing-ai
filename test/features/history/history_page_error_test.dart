import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:socratic_ai/features/history/history_page.dart';

/// HistoryPage 渲染测试
///
/// HistoryPage 通过 HistoryProvider 管理状态（Provider → ConversationService → Repository）。
/// 在测试环境中 sqflite 不可用，loadAll 会抛异常，页面应展示错误视图。
void main() {
  group('HistoryPage', () {
    testWidgets('在 DB 不可用时不崩溃并展示错误视图', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: HistoryPage()),
      );

      // 等待 loadAll 完成（失败后会显示错误视图）
      await tester.pumpAndSettle();

      // 页面应该不崩溃，并显示 storage icon + 重试按钮
      expect(find.byType(HistoryPage), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.byIcon(Icons.storage_outlined), findsOneWidget);
    });
  });
}
