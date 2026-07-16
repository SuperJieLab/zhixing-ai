# 2026-07-16 工作汇总

## 核心讨论：产品下一阶段方向

### 军师模式 + 全局面板

当前 Socratic AI 是"苏格拉底教练"（反思过去），下一阶段扩展为"军师/谋士"（规划未来）。

**关键认知**：
- 主动提醒、排期、定时任务依赖服务端能力（推送 + 定时调度）
- 但"意图理解 → 目标拆解 → 策略生成"可以在纯端侧做原型验证
- 先做 LLM prompt 原型 + 全局面板 UI，服务端并行推进

### 全局面板设计要点

- 每次对话结束后，LLM 额外提取 goals + strategies → 汇入 Dashboard
- 面板自动合并去重，跨对话关联
- 新数据模型：Goal / Strategy / CrossPattern
- 新 feature：dashboard（与现有 features 并存，不删旧代码）

### 实现策略

只增不改：旧页面不动，新 feature 独立开发。
等 Dashboard 成熟后再考虑替换 TopicSelection 作为主页。

## 产出文件

- `docs/notes/2026-07-16/design.md` — 军师模式完整设计文档（数据模型、数据流、LLM prompt、UI 布局、实现顺序）

## 待决策

- Goal 去重策略：自动合并 vs 用户确认
- 提取频率：每次对话 vs 批量
- 用户手动编辑：允许 vs 只读
- 本地通知：是否在服务端就绪前先上 flutter_local_notifications
- 相关性判断：LLM 需判断对话是否需要提取

## 已决策（Brainstorming 完成）

| 问题 | 决策 |
|------|------|
| 主页 | DashboardPage 唯一主页 |
| 新对话入口 | Dashboard [+] → ChatPage（军师模式） |
| Goal 卡片 | 暂不交互 |
| 对话模式 | StrategistPrompter（军师），SocraticPrompter 代码保留 |
| 对话结束 | ChatPage → StrategyBriefPage（新页面） |
| relevant=false | 仍进 StrategyBriefPage，展示轻量总结 |
| 返回 Dashboard | popUntil（ChatPage + StrategyBriefPage 一起出栈） |
| InsightsPage | 移入 _deprecated，代码保留 |
| MindMapPage | 移入 _deprecated（孤儿页面） |
| TopicSelectionPage | 移入 _deprecated |
| Goal 去重 | 相同 title 自动合并 |
| 提取频率 | 每次对话结束 |
| 用户编辑 | 全 AI 管理 |
| 提醒 | flutter_local_notifications 先行 |
| 相关性判断 | < 2 条用户消息跳过，否则 LLM 判断 |
