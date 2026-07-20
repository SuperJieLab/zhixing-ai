/**
 * services/push.js — 推送决策分发层
 * ====================================
 *
 * 【这个文件做什么】
 * 推送服务的"总调度"：根据设备的 mode（rules/llm），调用对应的引擎做决策，
 * 然后通过 sendPush() 发送推送。
 *
 * 【在架构中的位置】
 *   index.js (cron 定时器) → push.js (本文件)
 *                              ├── runRulesMode() → rules-engine.js（规则引擎）
 *                              └── runLLMMode()  → llm-engine.js（DeepSeek API）
 *                              ↓
 *                           sendPush() → console.log（MVP 占位，后续换 Firebase Admin SDK）
 *
 * 【三个导出函数】
 *   sendPush(token, notification)  — 发送推送（MVP：console.log 占位）
 *   runRulesMode(deviceStore)      — 遍历 rules 模式设备，调用规则引擎决策
 *   runLLMMode(deviceStore)        — 遍历 llm 模式设备，调用 DeepSeek 决策
 */

const { shouldPush: rulesShouldPush } = require('./rules-engine');
const { analyzePushDecision } = require('./llm-engine');

/**
 * 发送推送通知（占位函数）
 *
 * MVP 阶段用 console.log 代替真实 FCM 调用。
 * 后续替换为：
 *   const admin = require('firebase-admin');
 *   await admin.messaging().send({ token, notification: { title, body }, data });
 */
async function sendPush(deviceToken, notification) {
  console.log(`[push] → ${deviceToken.slice(0, 8)}...`);
  console.log(`[push]   title: ${notification.title}`);
  console.log(`[push]   body: ${notification.body}`);
  // TODO: 替换为真实 Firebase Admin SDK 调用
  return { sent: true, method: 'console' };
}

/**
 * 规则模式：扫描所有设备，决策 + 推送
 */
async function runRulesMode(deviceStore) {
  let pushed = 0;
  for (const [token, data] of deviceStore.entries()) {
    if (data.mode !== 'rules') continue;
    const decision = rulesShouldPush(data.goals, data.strategies);
    if (decision?.shouldPush) {
      await sendPush(token, {
        title: decision.title,
        body: decision.body,
        data: decision.data || {},
      });
      pushed++;
    }
  }
  return pushed;
}

/**
 * LLM 模式：对每个设备调用 DeepSeek 决策
 */
async function runLLMMode(deviceStore) {
  let pushed = 0;
  for (const [token, data] of deviceStore.entries()) {
    if (data.mode !== 'llm') continue;
    const decision = await analyzePushDecision(data.goals, data.strategies);
    if (decision?.should_push) {
      await sendPush(token, {
        title: decision.title || '知行AI 提醒',
        body: decision.body,
        data: { type: 'llm_reminder' },
      });
      pushed++;
    }
  }
  return pushed;
}

module.exports = { sendPush, runRulesMode, runLLMMode };
