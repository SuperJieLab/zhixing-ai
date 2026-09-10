/**
 * services/llm-engine.js — DeepSeek API 封装（推送决策专用）
 *
 *   analyzePushDecision(): 推送决策（push 定时任务使用），返回 { should_push, title, body }
 *
 * 对话转发链路已随 BYOK 直连改造移除（客户端直连用户自配的模型 API），
 * 服务端 LLM 仅剩推送决策这一自有业务。
 *
 * 容错约定：调用失败一律由调用方决定降级（push 跳过），引擎内不抛出未处理异常。
 * API 文档：https://platform.deepseek.com/api-docs
 */

/**
 * 推送决策（非流式，temperature 0.3 / max_tokens 200——小 JSON 决策输出）
 * 无 API Key 或调用失败均返回 null，由调用方跳过 LLM 推送。
 */
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
};
