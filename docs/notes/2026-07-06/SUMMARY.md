# 2026-07-06 工作总结

## 完成事项

### Day 3 — 对话引擎完善（梯度追问策略）

- v5 → v6 追问策略升级：固定维度轮换 → 梯度 ProbeStage（探索→深入→挑战→总结）
- Token 估算器实现：`LlamaService.estimateTokens()` 全链路追踪
- 上下文监控：累计 > 1800 tokens 日志警告
- 推理参数调优：temperature 0.85→0.5、maxTokens 256→128、新增 repeatPenalty=1.15

### Day 4 — 洞察总结

- InsightService：洞察提取 Prompt + JSON 三层回退解析
- InsightsPage UI：对话结束后的洞察展示页
- InsightsPage 双入口分支处理：`fromHistory` 参数区分交互行为

### Day 5a — 端侧会话持久化

- ConversationRepository（sqflite 单例）：建表、CRUD
- ConversationProvider：活跃会话生命周期 + 历史列表管理
- HistoryPage：历史对话列表 + 空状态 UI
- messages 和 insight 以 JSON 列整批覆盖存储

### 架构整顿（两轮）

- Page 层清理：ChatPage 移除对 engine/repository 的直接依赖
- 建立分层规范：pages → providers → engine/repository → models
- Provider 生命周期管理：ChatProvider（页面级）+ ConversationProvider（全局级）
- 跨 Provider 通信用回调注入，Page 层做胶水
- 解决 `late final` 闭包自引用、`ChangeNotifierProvider.create` 时序陷阱等编译问题

## 新增文件（15 个）

```
lib/core/models/conversation.dart
lib/core/engine/llama_service.dart（+engine getter +repeatPenalty +estimateTokens）
lib/features/chat/engine/socratic_prompter.dart（梯度策略重写）
lib/features/chat/providers/chat_provider.dart（+loadModel +endConversation）
lib/features/chat/chat_page.dart（精简为纯 UI + Provider 协调）
lib/features/insights/engine/insight_service.dart
lib/features/insights/insights_page.dart（+fromHistory）
lib/features/insights/widgets/*（4 个 widget 独立文件）
lib/features/history/engine/conversation_repository.dart
lib/features/history/providers/conversation_provider.dart
lib/features/history/widgets/conversation_card.dart
lib/features/history/history_page.dart
lib/main.dart（async init DB + Provider 注入）
test/core/models/conversation_test.dart
```

## 关键决策

- 分层违规判断标准：Page 层 import 了 engine/ 或 repository/ → 违规
- 跨 Provider 通信用回调注入，非 Provider 互相依赖
- ChatProvider 局部注入（离开页面销毁），ConversationProvider 全局注入（跨页面共享）
