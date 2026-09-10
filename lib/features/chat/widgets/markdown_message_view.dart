import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:zhixing_ai/core/ui/theme.dart';
import 'package:zhixing_ai/features/chat/engine/markdown_blocks.dart';

/// 流式 Markdown 渲染视图（抗闪烁核心）：
/// 已闭合块经 [splitBlocks] 切出后按文本缓存 Widget，delta 重建只重画尾块；
/// 尾块流式中始终以纯文本渲染，内联语法在整块闭合后才升级为富文本。
class MarkdownMessageView extends StatefulWidget {
  /// 全量文本，随 delta 增长
  final String content;

  /// 生成流是否已结束（false = 流式中）
  final bool isComplete;

  final TextStyle? baseStyle;

  const MarkdownMessageView({
    super.key,
    required this.content,
    this.isComplete = false,
    this.baseStyle,
  });

  @override
  State<MarkdownMessageView> createState() => _MarkdownMessageViewState();
}

class _MarkdownMessageViewState extends State<MarkdownMessageView> {
  /// 已闭合块文本 → 渲染好的 Widget。闭合块内容不可变，缓存避免重复解析。
  final Map<String, Widget> _cache = {};

  /// 复用同一个 Document 实例（扩展集固定），避免每次重建。
  static final md.Document _document =
      md.Document(extensionSet: md.ExtensionSet.gitHubFlavored);

  /// 解析内联内容时使用的基础样式；外部未提供时退化为默认正文样式。
  TextStyle get _base =>
      widget.baseStyle ??
      const TextStyle(
        fontSize: 15,
        height: 1.5,
        color: AppTheme.textPrimary,
      );

  @override
  Widget build(BuildContext context) {
    final text = widget.content;
    if (text.isEmpty) {
      return const SizedBox.shrink();
    }

    final split = splitBlocks(text, isComplete: widget.isComplete);
    final children = <Widget>[];

    for (final block in split.closed) {
      // 已闭合块按文本缓存，delta 重建只命中缓存、不重新解析
      children.add(_cache.putIfAbsent(block, () => _buildClosedBlock(block)));
    }

    if (split.tail.isNotEmpty) {
      // 尾块始终是纯文本（即便内含未闭合内联语法），避免闪烁
      children.add(Text(split.tail, style: widget.baseStyle));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  /// 把一个已闭合块解析为 Widget（可能含单个或多个顶层节点）。
  Widget _buildClosedBlock(String block) {
    final nodes = _document.parse(block);
    final widgets = <Widget>[];
    for (final node in nodes) {
      widgets.add(_buildNode(node));
    }
    if (widgets.isEmpty) return const SizedBox.shrink();
    if (widgets.length == 1) return widgets.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: widgets,
    );
  }

  Widget _buildNode(md.Node node, [TextStyle? base]) {
    if (node is! md.Element) {
      final t = node.textContent;
      if (t.isEmpty) return const SizedBox.shrink();
      return Text(t, style: base ?? _base);
    }

    switch (node.tag) {
      case 'p':
        return _buildParagraph(node, base);
      case 'h1':
        return _buildHeading(node, 17, base);
      case 'h2':
        return _buildHeading(node, 16, base);
      case 'h3':
        return _buildHeading(node, 15, base);
      case 'h4':
        return _buildHeading(node, 15, base);
      case 'h5':
        return _buildHeading(node, 14, base);
      case 'h6':
        return _buildHeading(node, 14, base);
      case 'pre':
        return _buildCodeBlock(node, base);
      case 'ul':
        return _buildList(node, false, base);
      case 'ol':
        return _buildList(node, true, base);
      case 'blockquote':
        return _buildBlockquote(node, base);
      case 'hr':
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: Divider(height: 1, thickness: 1, color: Color(0xFFE0E0E0)),
        );
      case 'table':
        return _buildTable(node, base);
      default:
        // 未知块标签：降级为纯文本
        final t = node.textContent;
        return t.isEmpty ? const SizedBox.shrink() : Text(t, style: base ?? _base);
    }
  }

  Widget _buildParagraph(md.Element e, [TextStyle? base]) {
    final b = base ?? _base;
    return RichText(
      text: TextSpan(style: b, children: _buildInline(e.children ?? const [], b)),
    );
  }

  Widget _buildHeading(md.Element e, double size, [TextStyle? base]) {
    final b = (base ?? _base).copyWith(
      fontSize: size,
      fontWeight: FontWeight.bold,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: RichText(
        text: TextSpan(style: b, children: _buildInline(e.children ?? const [], b)),
      ),
    );
  }

  /// 围栏代码块：浅灰底 + 深色等宽字，水平滚动避免溢出 260px 气泡。
  Widget _buildCodeBlock(md.Element e, [TextStyle? base]) {
    String code = '';
    for (final child in e.children ?? const <md.Node>[]) {
      if (child is md.Element && child.tag == 'code') {
        code = child.textContent;
        break;
      }
      code = child.textContent;
    }
    code = code.replaceAll(RegExp(r'\n$'), '');

    const bg = Color(0xFFF6F6F8);
    const fg = AppTheme.textPrimary;
    final codeStyle = TextStyle(
      fontFamily: 'monospace',
      fontSize: 12.5,
      color: fg,
      height: 1.4,
    );

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(code, style: codeStyle, softWrap: false),
      ),
    );
  }

  /// 列表（有序/无序）。处理一层嵌套：li 内的 p、直接内联文本、以及内嵌 ul/ol。
  Widget _buildList(md.Element list, bool ordered, [TextStyle? base]) {
    final b = base ?? _base;
    final items = <Widget>[];
    var index = 0;

    for (final li in list.children ?? const <md.Node>[]) {
      if (li is! md.Element || li.tag != 'li') continue;
      index++;
      final marker = ordered ? '${_listStart(list) + index - 1}.' : '•';

      final inlineBuffer = <md.Node>[];
      final itemWidgets = <Widget>[];

      void flush() {
        if (inlineBuffer.isNotEmpty) {
          itemWidgets.add(
            RichText(
              text: TextSpan(
                style: b,
                children: _buildInline(inlineBuffer, b),
              ),
            ),
          );
          inlineBuffer.clear();
        }
      }

      for (final c in li.children ?? const <md.Node>[]) {
        if (c is md.Element && c.tag == 'ul') {
          flush();
          itemWidgets.add(_buildList(c, false, b));
        } else if (c is md.Element && c.tag == 'ol') {
          flush();
          itemWidgets.add(_buildList(c, true, b));
        } else if (c is md.Element && c.tag == 'input') {
          // 任务列表复选框：v1 不渲染交互控件，跳过
        } else if (c is md.Element && c.tag == 'p') {
          flush();
          itemWidgets.add(_buildParagraph(c, b));
        } else {
          inlineBuffer.add(c);
        }
      }
      flush();

      items.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(marker, style: b),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: itemWidgets,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: items,
    );
  }

  /// 引用块：左侧灰边 + 略微减弱的文字颜色。
  Widget _buildBlockquote(md.Element e, [TextStyle? base]) {
    final b = (base ?? _base).copyWith(color: AppTheme.textSecondary);
    final children = <Widget>[];
    for (final c in e.children ?? const <md.Node>[]) {
      children.add(_buildNode(c, b));
    }
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: Colors.grey.shade300, width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }

  /// GitHub 表格：水平滚动避免溢出，表头加粗。
  Widget _buildTable(md.Element e, [TextStyle? base]) {
    final b = base ?? _base;
    final rows = <TableRow>[];
    var inHeader = true;

    for (final section in e.children ?? const <md.Node>[]) {
      if (section is! md.Element) continue;
      if (section.tag != 'thead' && section.tag != 'tbody') continue;
      for (final row in section.children ?? const <md.Node>[]) {
        if (row is! md.Element || row.tag != 'tr') continue;
        final cells = <Widget>[];
        for (final cell in row.children ?? const <md.Node>[]) {
          if (cell is! md.Element) continue;
          final cellStyle = b.copyWith(
            fontWeight: inHeader ? FontWeight.bold : FontWeight.normal,
          );
          cells.add(
            Padding(
              padding: const EdgeInsets.all(6),
              child: RichText(
                text: TextSpan(
                  style: cellStyle,
                  children: _buildInline(cell.children ?? const [], cellStyle),
                ),
              ),
            ),
          );
        }
        rows.add(TableRow(children: cells));
      }
      inHeader = false;
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        border: TableBorder.all(color: Colors.grey.shade300, width: 1),
        children: rows,
      ),
    );
  }

  /// 递归把内联节点转成 [InlineSpan] 列表。
  List<InlineSpan> _buildInline(List<md.Node> nodes, TextStyle base) {
    final spans = <InlineSpan>[];
    for (final node in nodes) {
      if (node is md.Text) {
        spans.add(TextSpan(text: node.text, style: base));
      } else if (node is md.Element) {
        switch (node.tag) {
          case 'strong':
            spans.addAll(
              _buildInline(node.children ?? const [], base.copyWith(fontWeight: FontWeight.bold)),
            );
          case 'em':
            spans.addAll(
              _buildInline(node.children ?? const [], base.copyWith(fontStyle: FontStyle.italic)),
            );
          case 'del':
            spans.addAll(
              _buildInline(
                node.children ?? const [],
                base.copyWith(decoration: TextDecoration.lineThrough),
              ),
            );
          case 'code':
            // 内联代码：等宽 + 浅灰底（用 Paint 背景，避免 WidgetSpan 基线问题）
            spans.add(
              TextSpan(
                text: node.textContent,
                style: base.copyWith(
                  fontFamily: 'monospace',
                  fontSize: (base.fontSize ?? 14) - 2,
                  background: Paint()..color = const Color(0xFFF0F0F2),
                ),
              ),
            );
          case 'a':
            // 仅 http/https 链接才显示为链接样式；否则当作普通文本
            final href = node.attributes['href'] ?? '';
            final safe = href.startsWith('http://') || href.startsWith('https://');
            final linkStyle = base.copyWith(
              color: safe ? AppTheme.primary : base.color,
              decoration: safe ? TextDecoration.underline : TextDecoration.none,
            );
            spans.addAll(_buildInline(node.children ?? const [], linkStyle));
          case 'br':
            spans.add(const TextSpan(text: '\n'));
          case 'img':
            // 图片 v1 只渲染 alt 文本，不做网络请求（隐私）
            final alt = node.attributes['alt'] ?? '';
            if (alt.isNotEmpty) spans.add(TextSpan(text: alt, style: base));
          default:
            // 未知内联元素：保持样式递归其子节点
            spans.addAll(_buildInline(node.children ?? const [], base));
        }
      }
    }
    return spans;
  }

  int _listStart(md.Element list) {
    final s = list.attributes['start'];
    return s == null ? 1 : (int.tryParse(s) ?? 1);
  }
}
