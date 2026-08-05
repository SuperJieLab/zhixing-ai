/**
 * index.js — 知行AI 推送服务 入口文件
 * ==========================================
 *
 * 【这个文件做什么】
 * 启动 Express HTTP 服务，负责两件事：
 *   1. 接收 Flutter App 上报的数据（通过挂载 sync 路由）
 *   2. 定时扫描所有设备数据，触发推送决策（通过 node-cron）
 *
 * 【在架构中的位置】
 *   入口层 → 往下调用 routes/sync（数据接收）、services/push（推送分发）
 *   被 Flutter App 通过 POST /api/sync 调用
 *
 * 【启动方式】
 *   npm start  或  node src/index.js
 *   默认端口 3000，可通过 .env 的 PORT 覆盖
 *
 * 【依赖链】
 *   index.js
 *     ├── routes/sync.js      ← 处理 POST /api/sync，内存存储设备数据
 *     └── services/push.js    ← 推送决策分发（规则模式 + LLM 模式）
 *           ├── rules-engine.js  ← 规则模式：deadline 检查
 *           └── llm-engine.js    ← LLM 模式：DeepSeek API 调用
 */

require('dotenv').config();
const express = require('express');

const app = express();
const PORT = process.env.PORT || 3000;

app.use(express.json());

const syncRouter = require('./routes/sync');
app.use('/api/sync', syncRouter);

const cron = require('node-cron');
const { runRulesMode, runLLMMode, sendPush } = require('./services/push');

// WebSocket 相关：ws 包 + 连接注册中心 wsHub
const { WebSocketServer } = require('ws');
const { register, unregister } = require('./services/wsHub');

// 每 30 分钟扫描一次
cron.schedule('*/30 * * * *', async () => {
  console.log('[cron] 推送扫描开始');
  const store = syncRouter.getStore();
  const rulesCount = await runRulesMode(store);
  const llmCount = await runLLMMode(store);
  console.log(`[cron] 完成：规则=${rulesCount} LLM=${llmCount}`);
});

app.get('/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// 调试用：绕过 cron，手动触发一次推送（仅开发便捷）
app.post('/api/debug-push', async (req, res) => {
  // 仅非生产环境暴露（避免生产被任意 token 触发推送）
  if (process.env.NODE_ENV === 'production') return res.sendStatus(404);
  const { device_token, title, body } = req.body || {};
  if (!device_token) return res.status(400).json({ error: 'device_token required' });
  try {
    const result = await sendPush(device_token, {
      title: title || '测试提醒',
      body: body || '这是一条调试推送',
    });
    res.json(result);
  } catch (err) {
    console.error('[debug-push] 推送失败:', err);
    res.status(500).json({ error: 'push failed', detail: String(err?.message || err) });
  }
});

const server = app.listen(PORT, () => {
  console.log(`知行AI 推送服务启动，端口 ${PORT}`);
});

// 在已有 HTTP 服务上挂 WebSocket，路径 /ws?token=...
const wss = new WebSocketServer({ server, path: '/ws' });
wss.on('connection', (ws, req) => {
  const url = new URL(req.url, 'http://localhost');
  const token = url.searchParams.get('token');
  if (!token) {
    ws.close();
    return;
  }
  register(token, ws);
  console.log(`[ws] 设备上线: ${token.slice(0, 8)}...`);
  ws.on('close', () => {
    unregister(token, ws);
    console.log(`[ws] 设备离线: ${token.slice(0, 8)}...`);
  });
  ws.on('error', () => unregister(token, ws));
});
