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

  testWidgets('端点转义的引号实体按 CommonMark 规范解码', (tester) async {
    await pumpTable(tester, '他说&quot;这个能用&quot;，我回&quot;那就行&quot;.');

    // 包内 DecodeHtmlSyntax 解码（encodeHtml:false 下不再编码回去）
    expect(find.textContaining('他说"这个能用"', findRichText: true),
        findsOneWidget);
    expect(find.textContaining('&quot;', findRichText: true), findsNothing);
  });

  testWidgets('裸引号原样显示（AST 不经编码）', (tester) async {
    // encodeHtml:false 下裸 " 直通 AST，任何模型都不会再触发实体乱码
    await pumpTable(tester, '他说"这个能用"。');

    expect(find.textContaining('他说"这个能用"', findRichText: true),
        findsOneWidget);
    expect(find.textContaining('&quot;', findRichText: true), findsNothing);
  });

  testWidgets('代码块里的 HTML 源码逐字保真（模型输出 HTML 场景）', (tester) async {
    const htmlDemo = '''
```html
<a href="x">&lt;p&gt;&nbsp;</a>
```
''';
    await pumpTable(tester, htmlDemo);

    // encodeHtml:false 下代码内容不经任何编码，AST 即模型原始代码
    expect(find.textContaining('<a href="x">&lt;p&gt;&nbsp;</a>'),
        findsOneWidget);
  });

  testWidgets('正文实体按 CommonMark 规范解码（代码域外不保留字面）', (tester) async {
    await pumpTable(tester, '用 &lt;b&gt; 标签加粗，用 &amp;amp; 表示与号');

    // 规范行为：&lt; 解码为 <，&amp;amp; 解一层为 &amp;（与浏览器一致）
    expect(find.textContaining('用 <b> 标签加粗，用 &amp; 表示与号',
        findRichText: true), findsOneWidget);
  });
}

  Finder findRichText(String text) => find.textContaining(text, findRichText: true);
