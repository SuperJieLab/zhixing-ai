const test = require('node:test');
const assert = require('node:assert/strict');
const { extractDeltas } = require('../src/services/sse-parse');

test('sse-parse: 一个完整帧在一个 chunk 内', () => {
  const { deltas, rest, done } = extractDeltas('data: {"choices":[{"delta":{"content":"你好"}}]}\n\n', '');
  assert.deepEqual(deltas, ['你好']);
  assert.equal(rest, '');
  assert.equal(done, false);
});

test('sse-parse: 帧被拆成两个 chunk（半包）', () => {
  // 注：spec 示例 chunk2 多写一个 '}'（拼接后 JSON 非法），此处用合法的 ']}' 以正确重组出完整帧
  const r1 = extractDeltas('data: {"choices":[{"delta":{"content":"你"}}', '');
  assert.deepEqual(r1.deltas, []);
  assert.ok(r1.rest.length > 0, '应留下半包残尾');

  const r2 = extractDeltas(']}\n\n', r1.rest);
  assert.deepEqual(r2.deltas, ['你']);
  assert.equal(r2.rest, '');
});

test('sse-parse: 一个 chunk 多个帧，按序返回多个 delta', () => {
  const chunk =
    'data: {"choices":[{"delta":{"content":"你"}}]}\n\n' +
    'data: {"choices":[{"delta":{"content":"好"}}]}\n\n';
  const { deltas } = extractDeltas(chunk, '');
  assert.deepEqual(deltas, ['你', '好']);
});

test('sse-parse: [DONE] 帧 → done=true，无 delta', () => {
  const { deltas, done } = extractDeltas('data: [DONE]\n\n', '');
  assert.deepEqual(deltas, []);
  assert.equal(done, true);
});

test('sse-parse: 非 data 行被忽略', () => {
  const chunk =
    ': keep-alive-comment\n' +
    'data: {"choices":[{"delta":{"content":"好"}}]}\n\n';
  const { deltas } = extractDeltas(chunk, '');
  assert.deepEqual(deltas, ['好']);
});

test('sse-parse: 畸形 JSON 帧被跳过且不抛错', () => {
  const chunk =
    'data: {not-json}\n\n' +
    'data: {"choices":[{"delta":{"content":"好"}}]}\n\n';
  assert.doesNotThrow(() => {
    const { deltas } = extractDeltas(chunk, '');
    assert.deepEqual(deltas, ['好']);
  });
});

test('sse-parse: delta 存在但 content 缺失（仅 role 的首帧）被跳过', () => {
  const chunk =
    'data: {"choices":[{"delta":{"role":"assistant"}}]}\n\n' +
    'data: {"choices":[{"delta":{"content":"好"}}]}\n\n';
  const { deltas } = extractDeltas(chunk, '');
  assert.deepEqual(deltas, ['好']);
});
