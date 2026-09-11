import 'package:flutter_test/flutter_test.dart';
import 'package:zhixing_ai/features/chat/engine/html_entity_decoder.dart';

/// 流式尾块实体预解码单元测试
///
/// 架构：Document 以 encodeHtml:false 构造后，解析域无需任何下游解码；
/// 解码器只服务流式尾块（未解析原始文本）的显示一致性。见 decoder 文档。
void main() {
  group('decodeProseEntities（流式尾块预解码）', () {
    test('端点/网关转义的引号还原', () {
      expect(decodeProseEntities('他说&quot;这个能用&quot;，我回&quot;那就行&quot;.'),
          '他说"这个能用"，我回"那就行".');
    });

    test('全角分号变体', () {
      expect(decodeProseEntities('他说&quot；这个能用&quot；'), '他说"这个能用"');
    });

    test('转义的裸 & 还原', () {
      expect(decodeProseEntities('AT&amp;T 与 &amp; 符号'), 'AT&T 与 & 符号');
    });

    test('其他实体字面量不被误伤', () {
      // 尾块预解码范围只有 &quot;/&amp;；&lt;/&nbsp; 等留给闭合后包内规范解码
      expect(
        decodeProseEntities('用 &lt;b&gt; 和 &amp;lt; 与 &nbsp; 表示'),
        '用 &lt;b&gt; 和 &lt; 与 &nbsp; 表示',
      );
    });

    test('双重转义只解一层（&amp;quot； → 字面 &quot；）', () {
      expect(decodeProseEntities('哪几个显示成了 &amp;quot；'), '哪几个显示成了 &quot；');
    });

    test('无实体文本原样返回', () {
      const plain = '普通中文文本，没有任何实体。';
      expect(decodeProseEntities(plain), plain);
    });

    test('门禁：实体与裸引号混排 = 正常讲解 HTML 的内容，不解码', () {
      const html = 'HTML 里 <a href="x">写法是 &quot;转义&quot; 吗';
      expect(decodeProseEntities(html), html);
    });
  });
}
