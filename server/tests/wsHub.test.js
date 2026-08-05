const test = require('node:test');
const assert = require('node:assert');
const { register, unregister, pushToToken } = require('../src/services/wsHub');

function fakeWs() {
  return { readyState: 1, sent: [], send(d) { this.sent.push(d); } };
}

test('pushToToken sends to registered sockets and returns count', () => {
  const ws = fakeWs();
  register('tok1', ws);
  const n = pushToToken('tok1', { type: 'push', title: 't', body: 'b' });
  assert.equal(n, 1);
  assert.equal(ws.sent.length, 1);
  assert.ok(ws.sent[0].includes('"title":"t"'));
  unregister('tok1', ws);
});

test('pushToToken returns 0 when no socket', () => {
  assert.equal(pushToToken('unknown', { type: 'push' }), 0);
});

test('pushToToken skips non-open sockets', () => {
  const ws = fakeWs();
  ws.readyState = 3; // CLOSED
  register('tok2', ws);
  assert.equal(pushToToken('tok2', { type: 'push' }), 0);
  unregister('tok2', ws);
});
