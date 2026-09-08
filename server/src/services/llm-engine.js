/**
 * services/llm-engine.js — LLM 模式推送决策（DeepSeek API）
 * ==========================================================
 *
 * 【这个文件做什么】
 * 将用户的目标和策略数据发给 DeepSeek Chat API，让大模型判断是否需要推送提醒，
 * 并生成个性化的推送文案。
 *
 * 【在架构中的位置】
 *   push.js → runLLMMode() → llm-engine.js → analyzePushDecision()
 *                                ↓
 *                         POST https://api.deepseek.com/chat/completions
 *                                ↓
 *                         返回 { should_push, title, body } 或 null（失败时）
 *
 * 【输入/输出】
 *   输入：goals[] + strategies[]（结构化摘要，不含对话原文）
 *   输出：DeepSeek 返回的 JSON → 解析为 { should_push, title, body }
 *
 * 【容错设计】
 *   - 无 API Key → 直接返回 null（push.js 会跳过，不会崩溃）
 *   - API 调用失败 → catch 后返回 null（优雅降级，不推送）
 *   - JSON 解析失败 → catch 后返回 null
 *
 * 【面试可聊】
 *   - 为什么不用 GPT-4？→ DeepSeek 成本低（百万 token 几毛钱）、中文好、国产合规
 *   - 为什么 temperature=0.3？→ 推送决策不需要创意，需要确定性
 *   - Prompt 设计：指定了 JSON 格式 + 50 字限制 + 行动号召力——工程化的 prompt 工程
 *
 * API 文档：https://platform.deepseek.com/api-docs
 */

const { extractDeltas } = require('./sse-parse');

// 聊天模式系统人设：目标管理助手（知行AI），中文回答，可用 Markdown 组织内容
const CHAT_SYSTEM_PROMPT =
  '你是"知行AI"——一个个人目标管理助手。请用简体中文回答用户，' +
  '可以合理使用 Markdown（如列表、加粗、代码块）来组织内容，让回答清晰易读。';

// 上游基础地址：测试时可用 DEEPSEEK_BASE_URL 指向本地 mock（懒读取，覆盖 require 顺序）
const DEEPSEEK_BASE_URL = process.env.DEEPSEEK_BASE_URL || 'https://api.deepseek.com';

/**
 * 流式聊天补全（DeepSeek chat/completions，stream=true）
 *   messages: [{role, content}]，role 为 'system' | 'user' | 'assistant'
 *   onDelta(text): 每收到一段增量 content 时回调
 *   signal: AbortSignal，用于取消传播（客户端断开时中断上游请求）
 *
 * 说明：本函数不校验 API Key（职责分离，由路由层负责 501）。
 * 无 key 也可被调用，但真实请求会因 401 失败；测试通过 mock 规避。
 */
async function streamChatCompletion(messages, { onDelta, signal } = {}) {
  const apiKey = process.env.DEEPSEEK_API_KEY;
  // 懒读取上游地址：测试时可通过 DEEPSEEK_BASE_URL 指向本地 mock，覆盖 require 顺序
  const baseUrl = process.env.DEEPSEEK_BASE_URL || DEEPSEEK_BASE_URL;

  const response = await fetch(baseUrl + '/chat/completions', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${apiKey}`,
      'Accept': 'text/event-stream',
    },
    body: JSON.stringify({
      model: 'deepseek-chat',
      messages: [{ role: 'system', content: CHAT_SYSTEM_PROMPT }, ...messages],
      stream: true,
      temperature: 0.7,
      max_tokens: 1024,
    }),
    signal,
  });

  if (!response.ok) {
    throw new Error(`upstream ${response.status}`);
  }

  let rest = '';
  let done = false; // 必须提到循环外：截断检查在 loop 结束后仍需读取此flag
  for await (const chunk of response.body) {
    // 注意：fetch 的 chunk 是 Uint8Array，其 toString('utf8') 不解码（返回数字串），
    // 需用 Buffer.from 转换；Buffer 兼容 Uint8Array。
    const text = Buffer.from(chunk).toString('utf8');
    const result = extractDeltas(text, rest);
    rest = result.rest;
    for (const d of result.deltas) {
      if (typeof onDelta === 'function') onDelta(d);
    }
    if (result.done) {
      done = true;
      break;
    }
  }

  // 上游「干净地」中途断开（没发 [DONE] 且还有半帧数据没吐完）时，
  // 静默 resolve 会让客户端误以为回答完整 → 必须抛错，路由层转成 error 帧。
  // 正常结束（done=true）或 rest 只剩空白时不算截断。
  if (!done && rest.trim().length > 0) {
    throw new Error('upstream closed mid-stream, answer truncated');
  }
}

async function analyzePushDecision(goals, strategies) {
  const apiKey = process.env.DEEPSEEK_API_KEY;

  // 无 API Key → 回退规则模式
  if (!apiKey || apiKey === 'sk-your-key-here') {
    console.log('[llm] 无 DeepSeek API Key，跳过 LLM 决策');
    return null;
  }

  const goalsSummary = goals
    .map((g) => `- [${g.status}] ${g.title}${g.deadline ? ` (截止: ${g.deadline})` : ''}`)
    .join('\n');

  const strategiesSummary = strategies
    .filter((s) => !s.completed)
    .map((s) => `- ${s.description}`)
    .join('\n');

  const prompt = `你是一个个人目标管理助手的推送决策模块。

用户当前的目标和策略：

目标：
${goalsSummary || '(无)'}

未完成策略：
${strategiesSummary || '(无)'}

请判断现在是否需要向用户发送推送提醒。

规则：
- 如果有即将到期的目标（未来3天内）或长期未推进的策略，应该推送
- 推送内容应简洁、具体、有行动号召力，不超过50字
- 如果所有目标都在正常推进中，可以不推送

请只返回 JSON，格式：
{"should_push": true/false, "title": "推送标题", "body": "推送内容"}`;

  try {
    const response = await fetch('https://api.deepseek.com/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model: 'deepseek-chat',
        messages: [
          { role: 'system', content: '你是一个推送决策助手，只返回 JSON。' },
          { role: 'user', content: prompt },
        ],
        temperature: 0.3,
        max_tokens: 200,
      }),
    });

    const data = await response.json();
    const content = data.choices?.[0]?.message?.content || '';

    // 解析 JSON（去除可能的 markdown 代码块）
    const jsonStr = content.replace(/```json\n?/g, '').replace(/```/g, '').trim();
    const result = JSON.parse(jsonStr);

    console.log(`[llm] decision: should_push=${result.should_push}`);
    return result;
  } catch (err) {
    console.error('[llm] DeepSeek API 调用失败:', err.message);
    return null; // 失败时返回 null，不推送
  }
}

module.exports = {
  analyzePushDecision,
  streamChatCompletion,
  DEEPSEEK_BASE_URL,
  CHAT_SYSTEM_PROMPT,
};
