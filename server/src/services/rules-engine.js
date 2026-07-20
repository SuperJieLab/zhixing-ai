/**
 * services/rules-engine.js — 规则模式推送决策
 * =============================================
 *
 * 【这个文件做什么】
 * 纯函数：根据目标的 deadline 和策略的完成状态，判断是否应该推送提醒。
 * 不依赖网络、不依赖数据库——纯粹的"if-else"规则引擎。
 *
 * 【在架构中的位置】
 *   push.js → runRulesMode() → rules-engine.js → shouldPush()
 *                                  ↓
 *                          返回 { shouldPush, title, body } 或 null
 *
 * 【决策规则】
 *   1. 没有任何未完成策略 → 不推送
 *   2. 有 active 目标 deadline 在未来 3 天内 → 推送"目标即将到期"
 *   3. 有未完成策略但没设截止日期 → 每天最多推送一次"今日待办"
 *
 * 【面试可聊】
 *   - 为什么用纯函数而非类？→ 无状态、易测试、无副作用
 *   - 为什么 3 天？→ 产品决策：太早骚扰用户，太晚来不及行动
 *   - 如何防止重复推送？→ 每日提醒用 created_at 做了"当天是否已同步"判断
 */

function shouldPush(goals, strategies) {
  const now = new Date();
  const threeDaysLater = new Date(now.getTime() + 3 * 24 * 60 * 60 * 1000);

  const pendingStrategies = strategies.filter((s) => !s.completed);

  if (pendingStrategies.length === 0) return null;

  // 检查是否有即将到期的目标
  for (const goal of goals) {
    if (!goal.deadline) continue;

    const deadline = new Date(goal.deadline);
    if (deadline > now && deadline <= threeDaysLater && goal.status === 'active') {
      const daysLeft = Math.ceil((deadline - now) / (1000 * 60 * 60 * 24));
      return {
        shouldPush: true,
        title: '目标即将到期',
        body: `「${goal.title}」还有 ${daysLeft} 天到期，当前有 ${pendingStrategies.length} 条策略待完成`,
        data: { type: 'goal_reminder', goal_title: goal.title },
      };
    }
  }

  // 有未完成策略但未设截止日期 → 每日提醒一次
  const lastSyncToday = strategies.some((s) => {
    if (!s.created_at) return false;
    const created = new Date(s.created_at);
    return created.toDateString() === now.toDateString();
  });

  if (pendingStrategies.length > 0 && !lastSyncToday) {
    return {
      shouldPush: true,
      title: '今日待办',
      body: `你有 ${pendingStrategies.length} 条策略待完成，打开 App 看看进展吧`,
      data: { type: 'daily_reminder' },
    };
  }

  return null;
}

module.exports = { shouldPush };
