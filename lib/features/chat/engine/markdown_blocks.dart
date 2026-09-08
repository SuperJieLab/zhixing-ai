/// 把随时间增长的全量文本切成 Markdown 块。
///
/// 返回 (closed, tail)：
///   closed — 已闭合块列表（以空行分隔、``` fence 配对完整），内容不会再变，可整体缓存后渲染
///   tail   — 尾块（仍可能在生长的半个段落/表格/代码块）；流未结束时只能降级为纯文本渲染
///
/// [isComplete] 表示流是否已结束：为 true 时，已配对完整的尾块会升级进 [closed]
/// （闭合瞬间升级一次，不横跳）。切分对 ``` 代码 fence 感知：未闭合 fence 内的空行
/// 不会切出新块。
/// 「以空行结尾」判定：允许空行含空白字符（如 'A\n \n'），但单个尾部换行不算
/// （流式场景下追加一个 '\n' 不应误把尾块判为已闭合）。
/// 顶层编译一次复用（逐 token 热路径，避免每次调用重新构造 RegExp）。
final RegExp _endsWithBlankLine = RegExp(r'\n[ \t]*\n[ \t]*$');

({List<String> closed, String tail}) splitBlocks(String fullText,
    {bool isComplete = false}) {
  if (fullText.isEmpty) {
    return (closed: const [], tail: '');
  }

  final lines = fullText.split('\n');
  final blocks = <List<String>>[];
  var current = <String>[];
  var inFence = false;

  for (final line in lines) {
    final isBlank = line.trim().isEmpty;
    final isFence = line.trimLeft().startsWith('```');
    if (isFence) {
      // 开/合 fence 行都归入当前块，并切换 fence 状态
      current.add(line);
      inFence = !inFence;
    } else if (isBlank) {
      if (inFence) {
        // 未闭合 fence 内的空行仍是块的一部分，不切分
        current.add(line);
      } else if (current.isNotEmpty) {
        // 块间空行闭合当前块；连续空行不会产生空块
        blocks.add(current);
        current = <String>[];
      }
    } else {
      current.add(line);
    }
  }
  if (current.isNotEmpty) {
    blocks.add(current);
  }

  if (blocks.isEmpty) {
    return (closed: const [], tail: '');
  }

  String blockText(List<String> b) => b.join('\n');

  final endsWithBlank = _endsWithBlankLine.hasMatch(fullText);

  if (!isComplete) {
    if (endsWithBlank) {
      // 文本以空行结尾：最后一块已终止，整体算闭合，无尾块
      return (closed: blocks.map(blockText).toList(), tail: '');
    }
    final closed = blocks.sublist(0, blocks.length - 1).map(blockText).toList();
    return (closed: closed, tail: blockText(blocks.last));
  }

  // isComplete == true：末尾未闭合 fence 的块仍是尾块，否则全部升级为闭合
  if (inFence) {
    final closed = blocks.sublist(0, blocks.length - 1).map(blockText).toList();
    return (closed: closed, tail: blockText(blocks.last));
  }
  return (closed: blocks.map(blockText).toList(), tail: '');
}
