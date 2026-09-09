/**
 * routes/chat.js — 流式对话路由（SSE）
 *
 * POST /api/chat：{ messages, systemPrompt? } → 向上游流式请求，增量以
 * `data: {"delta":"字"}` 透传，结束帧 `data: [DONE]`。
 * 客户端断开 → abort 上游；写前检查 writableEnded/destroyed 防对死 socket 写。
 */

const express = require('express');
const router = express.Router();
const { streamChatCompletion } = require('../services/llm-engine');

router.post('/', async (req, res) => {
  const { messages, systemPrompt } = req.body || {};

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

  // 1.5 校验可选 systemPrompt：客户端拼装的人设（含目标上下文），人设唯一
  //     出处在客户端，服务端只透传避免双份文本漂移。字符串 + 4KB 上限。
  let systemPromptNormalized;
  if (systemPrompt !== undefined) {
    if (typeof systemPrompt !== 'string') {
      return res.status(400).json({ error: 'systemPrompt must be a string when present' });
    }
    const trimmed = systemPrompt.trim();
    if (trimmed.length > 4000) {
      return res.status(400).json({ error: 'systemPrompt too long (max 4000 chars)' });
    }
    if (trimmed.length > 0) systemPromptNormalized = trimmed;
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

  // 4. 取消传播：客户端断开 → abort 上游。
  //    注意用 res 的 'close'——req 的在请求体读完即触发（误报）；
  //    且必须吞掉写错误，否则对死 socket 写 [DONE] 会以 EPIPE 打崩进程。
  const controller = new AbortController();
  res.on('close', () => {
    if (!res.writableFinished) controller.abort();
  });
  res.on('error', () => {});

  const safeWrite = (s) => {
    if (!res.writableEnded && !res.destroyed) res.write(s);
  };

  try {
    await streamChatCompletion(messages, {
      signal: controller.signal,
      systemPrompt: systemPromptNormalized,
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
