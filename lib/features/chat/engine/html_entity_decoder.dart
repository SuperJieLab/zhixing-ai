/// 防御性 HTML 实体解码（叶子渲染点兜底）。
///
/// 根因链（2026-09-10 定位）：
/// 1. `markdown` 包解析时会把文本里的裸 `"` 重新编码成 `&quot;`（`&`/`<`/`>`
///    同理），而我们把 AST 的 textContent 原样渲染，实体就显示成了乱码——
///    这对任何模型都会发生；
/// 2. 用户配置的某云端端点还系统性把输出引号转义成 `&quot;`（含全角分号
///    变体 `&quot；` 与双重转义 `&amp;quot;`），加重了该现象。
///
/// 因此解码必须挂在 markdown 解析**之后**的叶子渲染点（Text span/尾块/
/// 代码块），解析前解码会被 markdown 包再编码回去。
///
/// 门禁：文本同时含 `&quot` 实体与裸 `"` 时视为「正常讲解 HTML 的内容」
/// 不解码（该门禁只在原始文本域生效——markdown 解析域里裸引号已被包
/// 重新编码，门禁天然不触发）。
///
/// 双重转义只解一层：`&amp;quot;` 先用哨兵保护，解完还原为字面 `&quot;`。
library;

const Map<String, String> _entityMap = <String, String>{
  '&quot;': '"',
  '&quot；': '"', // 模型偶发的全角分号变体
  '&apos;': "'",
  '&apos；': "'",
  '&#39;': "'",
  '&#39；': "'",
  '&lt;': '<',
  '&lt；': '<',
  '&gt;': '>',
  '&gt；': '>',
};

/// 引号类实体（含双重转义形态）
final RegExp _quotEntity = RegExp(r'&(amp;)?quot[;；]');

/// 双重转义形态：&amp;quot; / &amp;lt; 等，保护后只解一层
final RegExp _doubleEscaped =
    RegExp(r'&amp;((?:quot|apos|#39|lt|gt|amp)[;；])');

const String _sentinel = '\u0000';

String decodeHtmlEntities(String input) {
  if (!input.contains('&')) return input;

  // 门禁：实体与裸引号混排 = 正常讲解 HTML 的内容，不动
  if (_quotEntity.hasMatch(input) && input.contains('"')) return input;

  var out = input.replaceAllMapped(_doubleEscaped, (m) => '$_sentinel${m[1]}');
  _entityMap.forEach((entity, char) {
    out = out.replaceAll(entity, char);
  });
  // 哨兵还原 + markdown 包对裸 & 的再编码（&amp;）还原为 &
  return out.replaceAll(_sentinel, '&').replaceAll('&amp;', '&');
}
