const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const express = require('express');
const chatRouter = require('../src/routes/chat');

// 用本地 mock 上游替代真实 DeepSeek（沙箱无 API Key）
// mock 在 POST /chat/completions 时返回 SSE，3 段 content 各间隔 30ms，最后是 [DONE]
function startMockUpstream() {
  return new Promise((resolve) => {
    const mock = http.createServer((req, res) => {
      if (req.method === 'POST' && req.url === '/chat/completions') {
        let body = '';
        req.on('data', (c) => (body += c));
        req.on('end', () => {
          res.writeHead(200, {
            'Content-Type': 'text/event-stream',
            'Cache-Control': 'no-cache',
            'Connection': 'keep-alive',
          });
          const frames = [
            'data: {"choices":[{"delta":{"content":"你"}}]}\n\n',
            'data: {"choices":[{"delta":{"content":"好"}}]}\n\n',
            'data: {"choices":[{"delta":{"content":"世界"}}]}\n\n',
            'data: [DONE]\n\n',
          ];
          let i = 0;
          const state = { framesSent: 0, closedEarly: false };
          const writeNext = () => {
            if (i >= frames.length) {
              res.end();
              return;
            }
            try {
              res.write(frames[i]);
              state.framesSent++;
              i++;
              setTimeout(writeNext, 30);
            } catch {
              /* 已断开 */
            }
          };
          // 客户端（本路由→上游）断开时记下「提前关闭」
          res.on('close', () => {
            if (state.framesSent < frames.length) state.closedEarly = true;
          });
          writeNext();
        });
      } else {
        res.writeHead(404);
        res.end();
      }
    });
    mock.listen(0, () => {
      const port = mock.address().port;
      resolve({ mock, port, state: null });
    });
  });
}

// 把 mock 的「提前关闭」状态暴露出来：用闭包共享 state
function startMockUpstreamWithState() {
  return new Promise((resolve) => {
    let sharedState = { framesSent: 0, closedEarly: false };
    const mock = http.createServer((req, res) => {
      if (req.method === 'POST' && req.url === '/chat/completions') {
        let body = '';
        req.on('data', (c) => (body += c));
        req.on('end', () => {
          res.writeHead(200, {
            'Content-Type': 'text/event-stream',
            'Cache-Control': 'no-cache',
            'Connection': 'keep-alive',
          });
          const frames = [
            'data: {"choices":[{"delta":{"content":"你"}}]}\n\n',
            'data: {"choices":[{"delta":{"content":"好"}}]}\n\n',
            'data: {"choices":[{"delta":{"content":"世界"}}]}\n\n',
            'data: [DONE]\n\n',
          ];
          let i = 0;
          const writeNext = () => {
            if (i >= frames.length) {
              res.end();
              return;
            }
            try {
              res.write(frames[i]);
              sharedState.framesSent++;
              i++;
              // 帧间隔放大，给「客户端断开→上游中断」留出可观测窗口
              setTimeout(writeNext, 150);
            } catch {
              /* 已断开 */
            }
          };
          res.on('close', () => {
            if (sharedState.framesSent < frames.length) sharedState.closedEarly = true;
          });
          writeNext();
        });
      } else {
        res.writeHead(404);
        res.end();
      }
    });
    mock.listen(0, () => resolve({ mock, port: mock.address().port, getState: () => sharedState }));
  });
}

function collectFrames(readable) {
  // readable: web ReadableStream（fetch 的 response.body）
  const out = [];
  return new Promise((resolve, reject) => {
    const reader = readable.getReader();
    const decoder = new TextDecoder();
    const pump = () => {
      reader.read().then(({ value, done }) => {
        if (done) return resolve(out);
        const text = decoder.decode(value, { stream: true });
        for (const line of text.split('\n\n')) {
          if (line.startsWith('data: ')) out.push(line.slice('data: '.length));
        }
        pump();
      }).catch(reject);
    };
    pump();
  });
}

test('chat 路由：流式转发三段 content + [DONE]', async () => {
  const { mock, port } = await startMockUpstream();
  const savedBase = process.env.DEEPSEEK_BASE_URL;
  const savedKey = process.env.DEEPSEEK_API_KEY;
  process.env.DEEPSEEK_BASE_URL = `http://127.0.0.1:${port}`;
  process.env.DEEPSEEK_API_KEY = 'test-key';

  const app = express();
  app.use(express.json());
  app.use('/api/chat', chatRouter);
  const server = app.listen(0);
  const appPort = server.address().port;

  try {
    const resp = await fetch(`http://127.0.0.1:${appPort}/api/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ messages: [{ role: 'user', content: 'hi' }] }),
    });
    assert.equal(resp.headers.get('content-type'), 'text/event-stream');
    const frames = await collectFrames(resp.body);
    assert.ok(frames.some((f) => f.includes('"delta":"你"')), '应有 你 帧');
    assert.ok(frames.some((f) => f.includes('"delta":"好"')), '应有 好 帧');
    assert.ok(frames.some((f) => f.includes('"delta":"世界"')), '应有 世界 帧');
    assert.ok(frames.includes('[DONE]'), '应有 [DONE] 帧');
  } finally {
    server.close();
    mock.close();
    process.env.DEEPSEEK_BASE_URL = savedBase;
    process.env.DEEPSEEK_API_KEY = savedKey;
  }
});

test('chat 路由：messages 缺失/非法 → 400', async () => {
  const app = express();
  app.use(express.json());
  app.use('/api/chat', chatRouter);
  const server = app.listen(0);
  const appPort = server.address().port;
  try {
    const r1 = await fetch(`http://127.0.0.1:${appPort}/api/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({}),
    });
    assert.equal(r1.status, 400);
    const r2 = await fetch(`http://127.0.0.1:${appPort}/api/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ messages: [{ role: 'user' }] }),
    });
    assert.equal(r2.status, 400);
  } finally {
    server.close();
  }
});

test('chat 路由：无 API Key → 501', async () => {
  const savedKey = process.env.DEEPSEEK_API_KEY;
  delete process.env.DEEPSEEK_API_KEY; // 路由在请求时读 key，故可调
  const app = express();
  app.use(express.json());
  app.use('/api/chat', chatRouter);
  const server = app.listen(0);
  const appPort = server.address().port;
  try {
    const resp = await fetch(`http://127.0.0.1:${appPort}/api/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ messages: [{ role: 'user', content: 'hi' }] }),
    });
    assert.equal(resp.status, 501);
    const body = await resp.json();
    assert.equal(body.error, 'cloud chat not configured');
  } finally {
    server.close();
    process.env.DEEPSEEK_API_KEY = savedKey;
  }
});

test('chat 路由：客户端断开 → 上游请求被中断（取消传播）', async () => {
  const { mock, port, getState } = await startMockUpstreamWithState();
  const savedBase = process.env.DEEPSEEK_BASE_URL;
  const savedKey = process.env.DEEPSEEK_API_KEY;
  process.env.DEEPSEEK_BASE_URL = `http://127.0.0.1:${port}`;
  process.env.DEEPSEEK_API_KEY = 'test-key';

  const app = express();
  app.use(express.json());
  app.use('/api/chat', chatRouter);
  const server = app.listen(0);
  const appPort = server.address().port;

  try {
    const clientAc = new AbortController();
    const resp = await fetch(`http://127.0.0.1:${appPort}/api/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ messages: [{ role: 'user', content: 'hi' }] }),
      signal: clientAc.signal,
    });
    // 只读第一帧就断开
    const reader = resp.body.getReader();
    const decoder = new TextDecoder();
    let buf = '';
    let gotFirst = false;
    while (!gotFirst) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      if (buf.includes('"delta":"你"')) gotFirst = true;
    }
    // 客户端断开 → 路由 req 'close' → abort 上游
    clientAc.abort();
    await reader.cancel().catch(() => {});

    // 轮询等上游感知 socket 关闭（固定 sleep 有时序脆弱性）
    const deadline = Date.now() + 2000;
    while (!getState().closedEarly && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 10));
    }
    const state = getState();
    assert.equal(state.closedEarly, true, '上游应感知到响应 socket 被提前关闭');
  } finally {
    server.close();
    mock.close();
    process.env.DEEPSEEK_BASE_URL = savedBase;
    process.env.DEEPSEEK_API_KEY = savedKey;
  }
});
