import 'package:test/test.dart';
import 'package:zhixing_ai/features/chat/engine/client/sse_parser.dart';

void main() {
  test('1. 单帧单 chunk → 载荷，done=false', () {
    final buf = SseBuffer();
    final out = buf.feed('data: {"delta":"你"}\n\n');
    expect(out, ['{"delta":"你"}']);
    expect(buf.done, isFalse);
  });

  test('2. 半包：分两次喂入 → 第一次空，第二次出载荷', () {
    final buf = SseBuffer();
    expect(buf.feed('data: {"del'), isEmpty);
    expect(buf.done, isFalse);
    final out = buf.feed('ta":"你"}\n\n');
    expect(out, ['{"delta":"你"}']);
    expect(buf.done, isFalse);
  });

  test('3. 帧边界恰好在 chunk 末尾 → 载荷被吐出（不卡在 rest）', () {
    final buf = SseBuffer();
    final out = buf.feed('data: A\n\n');
    expect(out, ['A']);
    expect(buf.done, isFalse);
  });

  test('4. 多帧单 chunk → 顺序载荷', () {
    final buf = SseBuffer();
    final out = buf.feed('data: A\n\ndata: B\n\ndata: C\n\n');
    expect(out, ['A', 'B', 'C']);
    expect(buf.done, isFalse);
  });

  test('5. [DONE]：收尾帧置 done，且不进返回列表', () {
    final buf = SseBuffer();
    final out = buf.feed('data: {"delta":"好"}\n\ndata: [DONE]\n\n');
    expect(out, ['{"delta":"好"}']);
    expect(buf.done, isTrue);
  });

  test('6. done 粘性：之后任何 feed 恒返回空', () {
    final buf = SseBuffer();
    buf.feed('data: [DONE]\n\n');
    expect(buf.done, isTrue);
    expect(buf.feed('data: {"delta":"x"}\n\n'), isEmpty);
    expect(buf.feed('data: A\n\n'), isEmpty);
  });

  test('7. 未完整帧留在 rest：少一个空行 → 空列表', () {
    final buf = SseBuffer();
    expect(buf.feed('data: {"delta":"你"}\n'), isEmpty);
    expect(buf.done, isFalse);
    // 补完空行后出载荷
    final out = buf.feed('\n');
    expect(out, ['{"delta":"你"}']);
  });

  test('8. 注释行被忽略', () {
    final buf = SseBuffer();
    final out = buf.feed(': keep-alive\n\ndata: {"delta":"你"}\n\n');
    expect(out, ['{"delta":"你"}']);
    expect(buf.done, isFalse);
  });

  test('9. data: 后无空格 → 仍解析', () {
    final buf = SseBuffer();
    final out = buf.feed('data:{"delta":"你"}\n\n');
    expect(out, ['{"delta":"你"}']);
  });

  test('10. 空/空白 chunk → 空列表（done 后 feed(\'\') 也空）', () {
    final buf = SseBuffer();
    expect(buf.feed(''), isEmpty);
    expect(buf.feed('   \n  '), isEmpty);
    buf.feed('data: [DONE]\n\n');
    expect(buf.done, isTrue);
    expect(buf.feed(''), isEmpty);
  });

  test('11. 同一帧内多 data 行 → 以 \\n 拼接', () {
    final buf = SseBuffer();
    final out = buf.feed('data: A\ndata: B\n\n');
    expect(out, ['A\nB']);
  });

  test('12. CRLF 容忍：\\r\\n\\r\\n 分割', () {
    final buf = SseBuffer();
    final out = buf.feed('data: {"delta":"你"}\r\n\r\n');
    expect(out, ['{"delta":"你"}']);
  });

  test('13. 空载荷 data:（无内容）→ 跳过，不返回空串', () {
    final buf = SseBuffer();
    final out = buf.feed('data:\n\n');
    expect(out, isEmpty);
  });

  test('14. 跨 chunk 拆分的帧 + 杂注空行边界', () {
    final buf = SseBuffer();
    expect(buf.feed('data: {"d'), isEmpty);
    expect(buf.feed('elta":"hi"}\n\n: ping\n\n'), ['{"delta":"hi"}']);
    expect(buf.done, isFalse);
  });

  test('15. 混合 CRLF 与 LF 容错', () {
    final buf = SseBuffer();
    final out = buf.feed('data: X\r\n\ndata: Y\n\n');
    expect(out, ['X', 'Y']);
  });

  test('16. 帧内仅注释/空白 → 不贡献载荷', () {
    final buf = SseBuffer();
    final out = buf.feed(': c1\n: c2\n\n');
    expect(out, isEmpty);
    expect(buf.done, isFalse);
  });

  test('17. \\r 恰好落在 chunk 边界 → 不产生幻影帧', () {
    final buf = SseBuffer();
    expect(buf.feed('data: A\r'), isEmpty);
    expect(buf.feed('\n\r\n'), ['A']);
    expect(buf.done, isFalse);
  });

  test('18. error 帧 → 原样透传载荷', () {
    final buf = SseBuffer();
    final out = buf.feed('data: {"error":"上游中断"}\n\ndata: [DONE]\n\n');
    expect(out, ['{"error":"上游中断"}']);
    expect(buf.done, isTrue);
  });
}
