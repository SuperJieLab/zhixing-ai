/**
 * routes/chat.js — 流式对话路由（SSE）
 * ======================================
 *
 * 【这个文件做什么】
 * 提供 POST /api/chat：接收对话消息，向上游 DeepSeek 发起流式请求，
 * 并把增量内容以 SSE（text/event-stream）逐帧透传给客户端。
 *
 * 【在架构中的位置】
 *   index.js 挂载本路由 → POST /api/chat
 *   services/llm-engine.js → streamChatCompletion() 负责真实流式调用
 *   services/sse-parse.js → extractDeltas() 负责解析上游 SSE（本路由不直接用，引擎内部用）
 *
 * 【请求/响应】
 *   请求体：{ messages: [{ role, content }] }
 *   响应：text/event-stream，每帧 data: {"delta":"字"}，结束帧 data: [DONE]
 *
 * 【关键设计】
 *   - messages 校验在路由层；API Key 缺失在路由层返回 501（职责分离）
 *   - 客户端断开 → AbortController.abort() 传播给上游 → 中断流式请求（节省资源）
 *   - 取消后写已无意义：写之前检查 res.writableEnded / res.destroyed
 */

const express = require('express');
const router = express.Router();
const { streamChatCompletion } = require('../services/llm-engine');

router.post('/', async (req, res) => {
  const { messages } = req.body || {};

  // 1. 校验 messages：非空数组，且每项有字符串 role/content
  if (
    !Array.isArray(messages) ||
    messages.length === 0 ||
    !messages.every(
      (m) =>
        m &&
        typeof m.role === 'string' &&
        typeof m.content === 'string'
    )
  ) {
    return res.status(400).json({ error: 'messages must be a non-empty array of { role, content }' });
  }

  // 2. 无 API Key（或占位 key）→ 501
  const apiKey = process.env.DEEPSEEK_API_KEY;
  if (!apiKey || apiKey === 'sk-your-key-here') {
    return res.status(501).json({ error: 'cloud chat not configured' });
  }

  // 3. SSE 响应头
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('X-Accel-Buffering', 'no');
  res.flushHeaders();

  // 4. 取消传播：客户端断开 → 中断上游请求
  //    注意：req 的 'close' 在请求体读完即触发（误报），故改用 res 的 'close'，
  //    并仅在响应未正常结束时 abort（正常结束 writableFinished=true，不中断）。
  const controller = new AbortController();
  res.on('close', () => {
    if (!res.writableFinished) controller.abort();
  });
  // 客户端断开后 finally 仍可能对死 socket 写 [DONE]，没有 error 监听器
  // 会以 EPIPE 未处理异常打崩进程，必须吞掉写错误。
  res.on('error', () => {});

  const safeWrite = (s) => {
    if (!res.writableEnded && !res.destroyed) res.write(s);
  };

  try {
    await streamChatCompletion(messages, {
      signal: controller.signal,
      onDelta: (text) => safeWrite(`data: ${JSON.stringify({ delta: text })}\n\n`),
    });
  } catch (err) {
    if (err.name === 'AbortError' || controller.signal.aborted) {
      // 客户端断开 → 静默
    } else if (!res.writableEnded && !res.destroyed) {
      if (!res.headersSent) {
        res.status(500).json({ error: 'chat failed', detail: String(err?.message || err) });
      } else {
        safeWrite(`data: ${JSON.stringify({ error: String(err?.message || err) })}\n\n`);
      }
    }
  } finally {
    safeWrite('data: [DONE]\n\n');
    if (!res.writableEnded && !res.destroyed) res.end();
  }
});

module.exports = router;
