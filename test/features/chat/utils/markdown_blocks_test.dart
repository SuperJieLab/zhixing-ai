import 'package:test/test.dart';
import 'package:zhixing_ai/features/chat/utils/markdown_blocks.dart';

void main() {
  test('单段纯文本 → ([], \'A\')', () {
    final r = splitBlocks('A');
    expect(r.closed, isEmpty);
    expect(r.tail, 'A');
  });

  test('两段 A\\n\\nB → ([A], B)', () {
    final r = splitBlocks('A\n\nB');
    expect(r.closed, ['A']);
    expect(r.tail, 'B');
  });

  test('以空行结尾 A\\n\\n → ([A], \'\')', () {
    final r = splitBlocks('A\n\n');
    expect(r.closed, ['A']);
    expect(r.tail, '');
  });

  test('未闭合 fence → ([], 整块)', () {
    final r = splitBlocks('```python\nprint(1)');
    expect(r.closed, isEmpty);
    expect(r.tail, '```python\nprint(1)');
  });

  test('闭合 fence 后接新段落', () {
    final r = splitBlocks('```python\nprint(1)\n```\n\n后续');
    expect(r.closed, ['```python\nprint(1)\n```']);
    expect(r.tail, '后续');
  });

  test('未闭合 fence 内的空行不切分', () {
    final r = splitBlocks('para\n\n```py\nx\n\ny');
    expect(r.closed, ['para']);
    expect(r.tail, '```py\nx\n\ny');
  });

  test('连续多个空行不产生空块', () {
    final r = splitBlocks('A\n\n\n\nB');
    expect(r.closed, ['A']);
    expect(r.tail, 'B');
  });

  test('isComplete:true 未闭合 fence 仍是尾块', () {
    final r = splitBlocks('```py\nx\n\ny', isComplete: true);
    expect(r.closed, isEmpty);
    expect(r.tail, '```py\nx\n\ny');
  });

  test('isComplete:true 闭合 fence 后接段落 → 全部闭合', () {
    final r = splitBlocks('```py\nx\n```\n\nB', isComplete: true);
    expect(r.closed, ['```py\nx\n```', 'B']);
    expect(r.tail, '');
  });

  test('行内未完成语法不切分', () {
    final r = splitBlocks('表头\n|---|\n**加粗');
    expect(r.closed, isEmpty);
    expect(r.tail, '表头\n|---|\n**加粗');
  });

  test('闭合 fence 后空行再无内容 → 全部闭合', () {
    final r = splitBlocks('```py\nx\n```\n\n');
    expect(r.closed, ['```py\nx\n```']);
    expect(r.tail, '');
  });

  // 额外用例，覆盖未列出的边界
  test('空串与仅含空白行 → ([], \'\')', () {
    for (final input in ['', '\n\n   \n']) {
      final r = splitBlocks(input);
      expect(r.closed, isEmpty);
      expect(r.tail, '');
    }
  });

  test('多段 + 尾块', () {
    final r = splitBlocks('A\n\nB\n\nC');
    expect(r.closed, ['A', 'B']);
    expect(r.tail, 'C');
  });

  test('isComplete:true 多段全部闭合', () {
    final r = splitBlocks('A\n\nB\n\nC', isComplete: true);
    expect(r.closed, ['A', 'B', 'C']);
    expect(r.tail, '');
  });

  test('isComplete:true 单段闭合 → 进 closed', () {
    final r = splitBlocks('A', isComplete: true);
    expect(r.closed, ['A']);
    expect(r.tail, '');
  });

  test('isComplete:false 单末尾换行不误判为闭合', () {
    final r = splitBlocks('A\n');
    expect(r.closed, isEmpty);
    expect(r.tail, 'A');
  });

  test('以含空白/制表符的空行结尾 → 仍判定为以空行结尾', () {
    for (final input in ['A\n \n', 'A\n\t\n']) {
      final r = splitBlocks(input);
      expect(r.closed, ['A']);
      expect(r.tail, '');
    }
  });
}
