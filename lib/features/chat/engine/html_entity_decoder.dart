/// 防御性 HTML 实体解码——分域精确逆变换（叶子渲染点兜底）。
///
/// 根因链（2026-09-11 实验摸底）：
/// 1. `markdown` 包对**正文**只转义裸 `"` → `&quot;` 与裸 `&` → `&amp;`，
///    `<`/`>`/既有实体原样保留；我们原样渲染 AST 文本，引号就显示成实体——
///    这对任何模型都会发生（主凶）；
/// 2. 包对**代码域**（行内代码/围栏代码块）整体转义 `& < > "`；
/// 3. 用户配置的某云端端点还系统性把输出引号转义成 `&quot;`（含全角分号
///    变体 `&quot；` 与双重转义 `&amp;quot;`），加重了该现象（帮凶）。
///
/// 因此解码挂在 markdown 解析**之后**的叶子渲染点，且按域区分：
/// - [decodeProseEntities]：正文 Text/流式尾块——只反解包实际转义的内容
///   （`&quot;` 全角变体 + `&amp;`），模型故意写的 `&lt;`/`&nbsp;` 等
///   实体字面量不被误伤；
/// - [decodeCodeEntities]：代码块/行内代码——完整逆变换（`& < > "` 全集），
///   把包的整体转义精确还原为模型原始代码。
///
/// 门禁：文本同时含 `&quot` 实体与裸 `"` 时视为「正常讲解 HTML 的内容」
/// 不解码（只在原始文本域生效——解析域里裸引号已被包再编码）。
/// 双重转义只解一层：`&amp;quot;` 先哨兵保护，解完还原为字面 `&quot;`。
library;

/// 正文域：包在正文里只转义这两个（`"` 与裸 `&`）
const Map<String, String> _proseMap = <String, String>{
  '&quot;': '"',
  '&quot；': '"', // 模型偶发的全角分号变体
};

/// 代码域：包在代码内容里整体转义 `& < > "`，做完整逆变换
const Map<String, String> _codeMap = <String, String>{
  '&quot;': '"',
  '&quot；': '"',
  '&lt;': '<',
  '&lt；': '<',
  '&gt;': '>',
  '&gt；': '>',
  '&apos;': "'",
  '&apos；': "'",
  '&#39;': "'",
  '&#39；': "'",
};

/// 引号类实体（含双重转义形态）
final RegExp _quotEntity = RegExp(r'&(amp;)?quot[;；]');

/// 双重转义形态：&amp;quot; / &amp;lt; 等，保护后只解一层
final RegExp _doubleEscaped =
    RegExp(r'&amp;((?:quot|apos|#39|lt|gt|amp)[;；])');

const String _sentinel = '\u0000';

String decodeProseEntities(String input) => _decode(input, _proseMap);

String decodeCodeEntities(String input) => _decode(input, _codeMap);

String _decode(String input, Map<String, String> map) {
  if (!input.contains('&')) return input;

  // 门禁：实体与裸引号混排 = 正常讲解 HTML 的内容，不动
  if (_quotEntity.hasMatch(input) && input.contains('"')) return input;

  var out = input.replaceAllMapped(_doubleEscaped, (m) => '$_sentinel${m[1]}');
  map.forEach((entity, char) {
    out = out.replaceAll(entity, char);
  });
  // 先兜底还原包对裸 & 的转义（&amp; → &），再还原哨兵——
  // 顺序反了的话，哨兵还原出的字面 &amp; 会被兜底再次吃掉
  return out.replaceAll('&amp;', '&').replaceAll(_sentinel, '&');
}
