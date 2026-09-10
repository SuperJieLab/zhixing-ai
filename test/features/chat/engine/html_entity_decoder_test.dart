import 'package:flutter_test/flutter_test.dart';
import 'package:zhixing_ai/features/chat/engine/html_entity_decoder.dart';

/// decodeHtmlEntities 单元测试
///
/// 根因链：①markdown 包解析时会把裸 `"` 再编码成 `&quot;`（任何模型都会触发
/// 显示乱码）；②用户配置的某云端端点还系统性转义引号（含全角分号变体与双重
/// 转义）。解码挂在叶子渲染点，见 decoder 文档。
void main() {
  group('应解码', () {
    test('markdown 包再编码的裸引号（&quot;）', () {
      expect(decodeHtmlEntities('他说&quot;这个能用&quot;，我回&quot;那就行&quot;.'),
          '他说"这个能用"，我回"那就行".');
    });

    test('全角分号变体', () {
      expect(decodeHtmlEntities('他说&quot；这个能用&quot；'), '他说"这个能用"');
    });

    test('ASCII 与全角分号混排', () {
      expect(
        decodeHtmlEntities('&quot;Hello&quot; 和 &quot；你好&quot；'),
        '"Hello" 和 "你好"',
      );
    });

    test('双重转义只解一层（&amp;quot; → 字面 &quot;）', () {
      expect(decodeHtmlEntities('哪几个显示成了 &amp;quot；'), '哪几个显示成了 &quot；');
      expect(decodeHtmlEntities('双转义 &amp;quot; 与裸引号 &quot; 混排'),
          '双转义 &quot; 与裸引号 " 混排');
    });

    test('单引号/尖括号实体一并处理', () {
      expect(
        decodeHtmlEntities("It&apos;s &lt;b&gt;bold&lt;/b&gt;"),
        "It's <b>bold</b>",
      );
    });

    test('markdown 包再编码的裸 &（&amp;）还原', () {
      expect(decodeHtmlEntities('AT&amp;T 与 &amp; 符号'), 'AT&T 与 & 符号');
    });
  });

  group('不解码（门禁拦截）', () {
    test('实体与裸引号混排 = 正常讲解 HTML 的内容', () {
      const html = 'HTML 里 <a href="x">写法是 &quot;转义&quot; 吗</a>';
      expect(decodeHtmlEntities(html), html);
    });

    test('无实体文本原样返回', () {
      const plain = '普通中文文本，没有任何实体。';
      expect(decodeHtmlEntities(plain), plain);
    });
  });
}
