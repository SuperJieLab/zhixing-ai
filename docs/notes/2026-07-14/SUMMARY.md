# 2026-07-14 总结

## 完成

### 架构重构 — 消除跨 Feature 耦合（3 次提交）

1. **ChatProvider 解耦洞察生成** (`feb7a53`)
   - ChatProvider 移除 `endConversation()` → 不再 import insight_service
   - InsightProvider 接管洞察生成/持久化（ChangeNotifier + generateInsights）
   - InsightsPage 直接管理 loading 态，不再由 ChatPage 弹 dialog

2. **跨 feature import 修复 + 死代码清理** (`3d9a363`)
   - `insights/providers → mindmap/engine/mindmap_service.dart` 违规 ← 唯一跨 feature engine import
   - MindMapService 删除 → 新建 MindMapProvider；SocraticPrompter.engine 死代码移除
   - InsightsPage 直接 navigate 到 MindMapPage，不再通过 Provider 代理

3. **ChatProvider 统一初始化** (`2009e3e`)
   - resumeConversationId + existingMessages → 统一为 `Conversation? conversation`
   - Provider 内部根据 null 判断新建/恢复，seedHistory 统一处理

### 参数简化

4. **InsightsPage 参数统一** (`80f8c84`)
   - 移除 `insight` 参数 → InsightProvider 通过 conversationId 查 DB 自判断
   - ChatPage 和 HistoryPage 两个入口使用完全相同 API

### Bug 修复

5. **历史对话恢复全链路修复** (`21218ad`)
   - resume 时历史消息回放到 LLM 引擎（SocraticPrompter.seedHistory）
   - 轮数显示对齐：ChatPage `_round - 1` 与 totalRounds 一致
   - 重复检测阈值 0.6 → 0.8（中文问句 LCS 误判）
   - 探索 hint 修正："帮用户展开这个话题" → "基于用户刚才的回答"
   - HistoryPage Provider scope 修复：State context → Consumer 内联
   - 空会话不落库：startConversation 延迟到首次 sendMessage

## 关键教训

### 架构认知

- **「跨 feature import engine」是红线**：chat→insights、insights→mindmap 两条都被清除
- **页面导航不要通过 Provider 代理**：InsightProvider.openMindMap() → InsightsPage 直接 navigate
- **Conversation 对象比零散参数好**：一个 `Conversation?` 替代 resumeConversationId + existingMessages
- **Provider scope 陷阱**：State 的 `this.context` 在 build 返回的 ChangeNotifierProvider 上方，找不到 provider

### 重构方法

- **重构后必须真机验证**：resume 模式的 seedHistory bug 在 analyze 下完全不可见
- **默认值的方向**：`_historyReplayed = true`（新对话）比 `false`（需回放）更安全
- **一次性回放 > 散装 seedContext**：seedHistory 统一了新建（欢迎语）和恢复（完整历史）

## 提交

```
2009e3e  refactor: simplify ChatProvider with Conversation? parameter
21218ad  fix: resume conversation context + round display + duplicate detection
3d9a363  refactor: fix cross-feature import + dead code cleanup
80f8c84  refactor: accept Conversation in InsightsPage
feb7a53  refactor: decouple insight generation from ChatProvider
```

5 commits, 0 error 0 warning, 跨 feature engine import 全部清零。
