import 'package:flutter_test/flutter_test.dart';
import 'package:zhixing_ai/features/chat/engine/html_entity_decoder.dart';

/// 分域实体解码单元测试
///
/// 根因链：①markdown 包对正文只转义 `"`/裸`&`，对代码域整体转义 `& < > "`；
/// ②某云端端点还系统性转义引号（含全角分号变体与双重转义）。解码按域做
/// 精确逆变换，见 decoder 文档。
void main() {
  group('decodeProseEntities（正文域：只反解包转义的 &quot; 与 &amp;）', () {
    test('包再编码的裸引号', () {
      expect(decodeProseEntities('他说&quot;这个能用&quot;，我回&quot;那就行&quot;.'),
          '他说"这个能用"，我回"那就行".');
    });

    test('全角分号变体（端点帮凶）', () {
      expect(decodeProseEntities('他说&quot；这个能用&quot；'), '他说"这个能用"');
    });

    test('包转义的裸 & 还原', () {
      expect(decodeProseEntities('AT&amp;T 与 &amp; 符号'), 'AT&T 与 & 符号');
    });

    test('模型故意写的实体字面量不被误伤', () {
      // &lt;/&nbsp;/&#39; 不在正文域解码范围（包也原样保留它们）；
      // &amp;lt; 解一层为 &lt;（与浏览器对 &amp; 的语义一致）
      expect(
        decodeProseEntities('用 &lt;b&gt; 和 &amp;lt; 与 &nbsp; 表示'),
        '用 &lt;b&gt; 和 &lt; 与 &nbsp; 表示',
      );
    });

    test('双重转义只解一层（&amp;quot; → 字面 &quot;）', () {
      expect(decodeProseEntities('哪几个显示成了 &amp;quot；'), '哪几个显示成了 &quot；');
    });

    test('无实体文本原样返回', () {
      const plain = '普通中文文本，没有任何实体。';
      expect(decodeProseEntities(plain), plain);
    });
  });

  group('decodeCodeEntities（代码域：完整逆变换，保真还原模型原始代码）', () {
    test('包整体转义的 HTML 源码还原', () {
      expect(
        decodeCodeEntities(
            '&lt;a href=&quot;x&quot;&gt;&amp;lt;p&amp;gt;&amp;nbsp;&lt;/a&gt;'),
        '<a href="x">&lt;p&gt;&nbsp;</a>',
      );
    });

    test('裸引号与实体字面量混排的代码还原', () {
      expect(
        decodeCodeEntities(
            'if (s == &quot;&amp;quot;&quot;) { print(&quot;&lt;b&gt;&quot;); }'),
        'if (s == "&quot;") { print("<b>"); }',
      );
    });

    test('无实体代码原样返回', () {
      const code = 'final x = [1, 2, 3];';
      expect(decodeCodeEntities(code), code);
    });
  });

  group('门禁（两域共用）', () {
    test('实体与裸引号混排 = 正常讲解 HTML 的内容，不解码', () {
      const html = 'HTML 里 <a href="x">写法是 &quot;转义&quot; 吗</a>';
      expect(decodeProseEntities(html), html);
      expect(decodeCodeEntities(html), html);
    });
  });
}
