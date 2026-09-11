/// 流式尾块的实体预解码（唯一使用场景：`splitBlocks` 未闭合尾块）。
///
/// 架构背景（2026-09-11）：`MarkdownMessageView` 的 Document 以
/// `encodeHtml: false` 构造——解析域的 AST 文本就是模型原始字符，标准实体
/// 由包内 `DecodeHtmlSyntax` 按 CommonMark 规范解码，下游**无需任何逆变换**。
///
/// 唯一例外是流式尾块：它是**未经过解析器**的原始文本。为保持与闭合块
/// （包内已解码）的显示一致，尾块渲染前在此做轻量预解码：
/// - 标准实体 `&quot;`（含模型/网关偶发的全角分号变体）→ `"`
/// - `&amp;` → `&`
/// - 双重转义只解一层：`&amp;quot;` → 字面 `&quot;`（哨兵保护）
///
/// 门禁：原始文本同时含 `&quot` 实体与裸 `"` 时视为「正在讲解 HTML 的
/// 内容」不解码——该门禁只在此原始文本域有意义；解析域里标准实体已由
/// 包内解码，不存在歧义。
library;

const Map<String, String> _proseMap = <String, String>{
  '&quot;': '"',
  '&quot；': '"', // 模型/网关偶发的全角分号变体
};

/// 引号类实体（含双重转义形态）
final RegExp _quotEntity = RegExp(r'&(amp;)?quot[;；]');

/// 双重转义形态：&amp;quot; / &amp;amp; 等，保护后只解一层
final RegExp _doubleEscaped = RegExp(r'&amp;((?:quot|amp)[;；])');

const String _sentinel = '\u0000';

String decodeProseEntities(String input) {
  if (!input.contains('&')) return input;

  // 门禁：实体与裸引号混排 = 正常讲解 HTML 的内容，不动
  if (_quotEntity.hasMatch(input) && input.contains('"')) return input;

  var out = input.replaceAllMapped(_doubleEscaped, (m) => '$_sentinel${m[1]}');
  _proseMap.forEach((entity, char) {
    out = out.replaceAll(entity, char);
  });
  // 先兜底还原裸 & 的转义（&amp; → &），再还原哨兵——
  // 顺序反了的话，哨兵还原出的字面 &amp; 会被兜底再次吃掉
  return out.replaceAll('&amp;', '&').replaceAll(_sentinel, '&');
}
