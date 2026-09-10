import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhixing_ai/features/chat/widgets/markdown_message_view.dart';

/// MarkdownMessageView 表格渲染测试
///
/// 背景 bug：Table 包在水平 SingleChildScrollView（无界宽度）里，
/// 默认 FlexColumnWidth 拿不到可分配空间，列宽塌缩成最小值，
/// 单元格逐字换行竖排。修复后列宽按内容自然宽度（IntrinsicColumnWidth）。
void main() {
  const table = '''
| 时间 | 跑通 Gemo | 评测条测试集 |
| --- | --- | --- |
| 周一 | 本地跑通 Gemo demo | 评测条 v2 全量 |
| 周三 | 修 bug | 补用例 |
''';

  Future<void> pumpTable(WidgetTester tester, String content) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: MarkdownMessageView(content: content, isComplete: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('表格单元格按内容宽度渲染，不塌缩成逐字换行', (tester) async {
    await pumpTable(tester, table);

    // 找到含「评测条测试集」的单元格文本，宽度应远大于塌缩时的单字宽（~15px）。
    // 测试环境 Ahem 字体每字符恰为 fontSize 宽，6 字单行 ≈ 90px。
    final cellText = findRichText('评测条测试集');
    expect(cellText, findsOneWidget);
    final width = tester.getSize(cellText).width;
    expect(width, greaterThan(50), reason: '列宽塌缩时该文本会逐字换行，宽度 ≈ 单字宽');
  });

  testWidgets('超宽表格不溢出布局（水平滚动兜底）', (tester) async {
    const wide = '''
| 列一 | 列二 | 列三 | 列四 | 列五 | 列六 | 列七 | 列八 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| aaaaaaaaaaaaaaaaaaaaaa | bbbbbbbbbbbbbbbbbbbbbb | cccccccccccccccccccccc | dddddddddddddddddddddd | eeeeeeeeeeeeeeeeeeeeee | ffffffffffffffffffffff | gggggggggggggggggggggg | hhhhhhhhhhhhhhhhhhhhhh |
''';

    await pumpTable(tester, wide);

    // 8 列长文本远超 300px 约束：无异常抛出 + 表格实际宽度超出视口（可横向滚动）
    final tableFinder = find.byType(Table);
    expect(tableFinder, findsOneWidget);
    expect(tester.getSize(tableFinder).width, greaterThan(300));
  });
}

  Finder findRichText(String text) => find.textContaining(text, findRichText: true);
