const test = require('node:test');
const assert = require('node:assert');
const push = require('../src/services/push');
const wsHub = require('../src/services/wsHub');

test('sendPush delivers via wsHub and reports count', async () => {
  let captured;
  wsHub.pushToToken = (token, payload) => { captured = { token, payload }; return 2; };
  const res = await push.sendPush('devX', { title: '标题', body: '内容' });
  assert.equal(res.delivered, 2);
  assert.equal(captured.token, 'devX');
  assert.equal(captured.payload.type, 'push');
  assert.equal(captured.payload.title, '标题');
  assert.equal(captured.payload.body, '内容');
});
