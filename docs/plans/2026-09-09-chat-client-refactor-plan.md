# 知行AI — ChatClient 接口抽取实施计划

> 状态：待执行
> 设计：`docs/plans/2026-09-09-chat-client-refactor-design.md`（已确认）
> 纪律：每 Task 实现 → 自查 → 改动留工作区，由用户确认后提交；不自动 commit。

## Task 1：接口 + 策略抽取（纯新增，不动现有调用方）

**文件**
- 新增 `lib/features/chat/engine/chat_client.dart`：`abstract class ChatClient`（isReady / initialize / generateResponse / stop / dispose）
- 新增 `lib/features/chat/engine/conversation_strategy.dart`：从 `strategist_prompter.dart` 原样搬出 `buildSystemPrompt`（含 goals 注入）、`isDuplicate`、`_lcsSimilarity`、`_recentQuestions` 滚动窗口
- 新增 `test/conversation_strategy_test.dart`

**验证**
- [ ] 策略单测绿：去重（相同/相似 >0.8/不同问题滚动 5 条窗口）、提示词含/不含 goals 两态
- [ ] `flutter analyze` 0 issues
- 此 Task 结束时旧 `StrategistPrompter` 仍在用（内部逻辑暂不删），保证可随时停下不破坏现有功能

## Task 2：LocalChatClient

**文件**
- 新增 `lib/features/chat/engine/local_chat_client.dart`：实现 `ChatClient`
  - 窄接口 `Session`（createChat/addUser/addAssistant/generate/dispose 最小抽象，默认实现包 llama `EngineChat`），测试用 fake 注入
  - `generateResponse(history)`：`skip(_consumed)` 增量 append；尾部用户消息过 `strategy.isDuplicate` 决定 session 侧改写；>75% 估算触发截断重建；think 剥离流式原样搬迁
  - `initialize`：buildSystemPrompt → createChat → addSystem；`stop()` 空实现
- 新增 `test/local_chat_client_test.dart`（fake Session）

**验证**
- [x] 单测绿：增量 append（二次调用只加新增）、消费条数推进、去重改写仅影响 session 侧、截断后 session 重建且 mirror 保留最近 12 条、think 标签剥离、取消时不登记 assistant 轮
- [x] 旧 `StrategistPrompter` 未动，Provider 仍走旧路径，全量测试不回归（93 过 / 6 失败，失败均为已知 Task 4 范围）

## Task 3：CloudChatClient 签名对齐

**文件**
- 改造 `lib/features/chat/engine/cloud_chat_client.dart`：
  - `generateResponse(List<ChatMessage> history)`：滤 round==0 → 尾部 10 条窗口 → 映射 ChatTurn → 走原 SSE 内核（不动）
  - `initialize({existingGoals})`：暂存字段，返回 true；`isReady` 恒 true
  - 实现 `ChatClient`
- 迁移 `test/cloud_chat_client_test.dart` 到新签名，新增窗口/过滤断言

**验证**
- [x] 云端单测绿（真 HttpServer）：round==0 被滤、>10 条取尾部、SSE/超时/取消行为不回归（6/6，A–F）
- [x] 此 Task 后 Provider 暂不可编译（签名变了，仅 chat_provider.dart:293 + tool/cloud_smoke.dart 两处调用点）——与 Task 4 同批提交或先合入 Task 4 再验

## Task 4：ChatProvider 接入单 client

**前置：存量测试债修复（2026-09-09 已完成，随本 Task 一起提交）**

`flutter test` 全量在 main 上本就红（约 20 个），修复内容（均为测试/配置层，零生产逻辑改动）：
- chat_provider_test / chat_page_error_test / chat_page_test / smoke_test：`setUpAll` 里 `SharedPreferences.setMockInitialValues({}) + SettingsRepository.instance.initialize()`（Task 6 给 ChatProvider 构造器加 chatCloudMode 后漏更新）
- 同上两文件：`_dummyConv` 改为每次 makeProvider 新建（共享实例会被 Provider 就地变更，泄漏状态）+ 消息列表给可增长 `<ChatMessage>[]`（默认 `const []` 不可变）+ 注入 `_NoopConversationService`（sendMessage finally 的 saveMessages 不再打真 DB）
- chat_bubble_test：AI 消息经 MarkdownMessageView 渲染，断言改 `find.textContaining(..., findRichText: true)`
- `test/llama_integration_test.dart` → `tool/`（独立 dart run 脚本，不该被 flutter test 收割；README 目录树已同步）
- analysis_options.yaml 排除 `build/**`（SourcePackages 第三方示例代码造成 13242 误报）+ tool 脚本 ignore_for_file

**发现（须在 Task 4 落地的注入缝）**：剩余 6 个失败（smoke_test ×4、chat_page_test ×2）根因有二：
1. `ChatPage` 内部硬创建 `ChatProvider` → `LlamaService.ensureReady`；macOS 宿主上真实 dylib 可加载，FFI 异步回调在 widget 测试 FakeAsync zone 中永不完成 → pumpAndSettle 超时（测试注释「FFI 快速失败」假设已失效）
2. app 装配层（ZhixingApp initState）启动 SyncService / PushSocketService，WS 连不上的重连 Timer 挂到测试收尾 → "Timer is still pending"

因此 Task 4 除 Provider 的 `ChatClient` 注入外，还需给 `ChatPage`（可选 provider factory 或 client 参数）与 `ZhixingApp`（背景服务开关参数）补测试缝。

**文件**
- 改造 `lib/features/chat/providers/chat_provider.dart`：
  - 单 `ChatClient _client` 字段；构造参数 `ChatClient? client` 注入缝，默认按 `chatCloudMode` 选实现
  - `loadModel` → `_client.initialize(existingGoals: activeGoals)`（云端模式不再加载本地模型）
  - `_sendLocal/_sendCloud` 合并、seed 分支删除、`stopGeneration` 只调 `_client.stop()`
  - 降级逻辑只看异常类型/内容状态
- 删除 `lib/features/chat/engine/strategist_prompter.dart`
- 排查全仓引用：`grep -r StrategistPrompter`（docs/learning-notes 不改，代码引用清零）

**验证**
- [x] 新增/迁移 Provider 测试（fake ChatClient）：流式缓冲写回、stopGeneration 半截保留且走 finally、TimeoutException 文案、空内容 Mock 降级、消息持久化（7 个新测试）
- [x] `flutter analyze` 0 issues；全量 `flutter test` **109/109 绿**（遗留 6 个失败已随注入缝落地全部修复：smoke ×4、chat_page ×2）
- [x] 实施中发现并修复 LocalChatClient diff 契约缺口：正常完成后下一轮 diff 会把已登记的 assistant 回复重复 append 进 session（Task 2 测试恰好未断言此条）——`_unregisteredAi` 改为 `_skipNextHistoryAi`，finally 无条件置位（已登记→防重复；未登记→有意缺席），并补双重登记断言
- [x] 附带落地：ChatPage `providerFactory` 注入缝（页面不 import engine 层，守分层规范）；DashboardRepository 注入缝；SyncService.enabled 测试开关（Dio Timer 在 FakeAsync zone 挂尾根因）；smoke_test 3 用 chat_cloud_mode=true 走云端默认工厂绕开 FFI

## Task 5：收尾

- [ ] 手工冒烟：本地模式对话（含恢复会话）、云端模式对话、停止生成、断网降级 Mock（用户侧执行）
- [x] 提交：Task 1+2（b07a726 / 562a623 / 03bf357）与 Task 3+4（6408e6f）分批入库，全量 109/109 绿
- [x] 更新 `MEMORY.md`：v2 候选①标记完成，记录 LocalChatClient/ConversationStrategy 新结构；②的前置（initialize 暂存 goals）就位
- [x] 周边一致性：README 无残留；docs/PROJECT.md 有 4 处漂移，已按「建议：」列给用户（历史 notes/plans 按约定不动）

## 依赖关系

```
Task 1 ──▶ Task 2 ──┐
                    ├──▶ Task 4 ──▶ Task 5
Task 1 ──▶ Task 3 ──┘
```

Task 2 / 3 依赖 Task 1 的接口与策略；Task 4 依赖 2+3 全部就位（签名切换是一次性动作，中途不保证可编译）；Task 3 单独落地会短暂破坏 Provider 编译，故 3+4 视为一个提交单元。

## 关键实现备忘（从设计文档摘录）

- 去重语义：`isDuplicate` 判重时**不**追加 last（避免相邻同问反复改写）
- 恢复会话：本地欢迎语（round==0）也 seed 进 session；diff 方案初始 `_consumed = 0` 自然覆盖
- 取消语义：本地流被取消订阅 → llama token 流弃用，session **不**登记该轮 assistant（保持现状）
- 估算 tokens：`LlamaService.estimateTokens` 沿用；欢迎语计入
