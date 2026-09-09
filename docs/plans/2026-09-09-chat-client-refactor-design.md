# 知行AI — ChatClient 接口抽取（v2 重构候选①）

> 状态：设计已确认（2026-09-09 对话确认，两个决策点用户已拍板）
> 关联：`MEMORY.md` v2 重构候选①②；②（云端系统提示词对等性）以本文档为前置

## 1. 背景与目标

流式对话 7 Task 落地后（`af514e3` → `9fd62b6`），对话引擎存在两种不对称实现：

| | StrategistPrompter（本地） | CloudChatClient（云端） |
|---|---|---|
| 签名 | `generateResponse(String)` 单条 | `generateResponse(List<ChatTurn>)` 完整历史 |
| 历史状态 | 自己持有（llama session + mirror） | 无状态，Provider 每轮现拼窗口 |
| 策略（去重 LCS / 75% 截断 / 系统提示词+goals / think 剥离） | 全部内嵌 | 全部没有 |
| stop | 无（靠 Provider 取消订阅） | 有（CancelToken + 订阅取消） |

后果：
- `StrategistPrompter` 是「策略层 + 传输层」合体，改名 `LocalChatClient` 会名不副实；
- `ChatProvider` 持双引擎字段（`_engine` + `_cloud`），`sendMessage`/`stopGeneration`/seed 逻辑按 `_mode` 分支，无法用 fake 做纯单测；
- 签名差异（单条 String vs 完整历史）与上述同根：历史状态归属不一致。

目标：抽 `abstract ChatClient`，拆出**纯传输**的两个实现 + **独立共享**的 `ConversationStrategy`，Provider 收敛为单 client 无模式分支。

## 2. 已确认的决策

| 决策点 | 结论 |
|---|---|
| **签名方向** | 统一收完整历史：`generateResponse(List<ChatMessage> history)`，新消息在尾部；两个 client 自己 diff / 取窗口。Provider 彻底无模式分支；local 保持增量 append，无重复 prefill 代价 |
| **策略归属** | 独立 `ConversationStrategy` 共享：local 全用（去重+截断+提示词），cloud 先只系统提示词（②落地后随请求体发送）。为②铺路，人设对等 |
| **隐私边界（②相关前置结论）** | 云端模式下对话明文本就发往服务端，goals 随请求体走同一信任边界，不构成新暴露面。②可走「请求体带 goals、服务端拼装」路线；建议数据最小化（只带 title+status） |

## 3. 接口设计

```dart
// lib/features/chat/engine/chat_client.dart
abstract class ChatClient {
  bool get isReady;

  /// 本地：组装系统提示词（strategy）→ 建 llama session；
  /// 云端：暂存 goals（本任务不发送，②启用）。
  Future<bool> initialize({List<Goal> existingGoals = const []});

  /// 完整对话历史（含本轮新用户消息，含 round==0 欢迎语）。
  /// 实现方自行决定：diff 增量（local）或 过滤+窗口（cloud）。
  Stream<String> generateResponse(List<ChatMessage> history);

  void stop();    // local 空实现（Provider 取消订阅已足够）；cloud 取消 socket+token
  void dispose();
}
```

签名收 `ChatMessage` 全模型（而非 `ChatTurn` record）的理由：round 信息随行，云端过滤欢迎语（round==0）的逻辑可以收进 client，Provider 的角色映射代码整体删除。

## 4. 文件切分与职责

```
lib/features/chat/engine/
  chat_client.dart           # abstract ChatClient（新）
  conversation_strategy.dart # 策略：系统提示词组装(含goals) / LCS去重 / 截断参数（新）
  local_chat_client.dart     # 纯传输：llama session 管理 + think 剥离 + 75%截断触发（新）
  cloud_chat_client.dart     # 纯传输：现有 SSE 逻辑，签名对齐（改造）
  strategist_prompter.dart   # 删除（拆入上面两个文件）
```

### 4.1 ConversationStrategy（从 StrategistPrompter 原样搬出）

- `String buildSystemPrompt({List<Goal> existingGoals})` —— 人设 + goals 上下文，static → 实例方法
- `bool isDuplicate(String input)` + `_lcsSimilarity` —— 含 `_recentQuestions` 滚动窗口（>0.8 判重、重复时**不**追加，语义保持）
- 纯逻辑无外部依赖，可独立单测

### 4.2 LocalChatClient（吸收 StrategistPrompter 的传输职责）

- 持有：`LlamaEngine`、llama `EngineChat? _chat`、session 侧历史 mirror、已消费条数 `_consumed`、token 估算
- `generateResponse(history)`：
  - 对 `history.skip(_consumed)` 逐条 append 进 session（保持增量 prefill，不整段重放；恢复会话 seed 行为与原 `seedHistory` 等价——欢迎语 round==0 也会 seed 为 assistant 轮）
  - 尾部新用户消息过 `strategy.isDuplicate` 决定是否在 **session 侧**改写为「请从不同角度回答…」（Provider 存储的仍是用户原文，与现状一致）
  - 超 75% 窗口触发 `_truncateContext`（重建 session + 按 mirror 重放，原样搬迁）
  - think 标签剥离流式逻辑原样搬迁（Qwen 模型特性，属本地传输关切）
- `initialize`：`strategy.buildSystemPrompt` → `createChat` → `addSystem`
- 依赖收敛：llama session 交互收敛到窄接口（见 §6 测试策略）

### 4.3 CloudChatClient（签名对齐，SSE 内核不动）

- `generateResponse(List<ChatMessage> history)`：内部 **滤 round==0 → 尾部 10 条窗口 → 映射 ChatTurn**（整体从 Provider `_sendCloud` 搬入），其余 UTF-8 解码 / SseBuffer / 帧间超时 / CancelToken / stop 传播全部不动
- `initialize`：暂存 `existingGoals` 字段（本任务不发送，②启用）
- 实现 `ChatClient`

### 4.4 ChatProvider（瘦身）

- `_engine` + `_cloud` 两字段 → 单 `ChatClient _client`：构造参数可注入（测试缝），默认按 `SettingsRepository.instance.chatCloudMode` 选 `CloudChatClient` / `LocalChatClient`
- `loadModel` → 调 `_client.initialize(existingGoals: activeGoals)`；**行为变化（有意）**：云端模式不再 ensureReady 本地模型，输入解锁更快（降级路径用的是 Mock 而非本地引擎，无依赖）
- `_sendLocal/_sendCloud` 合并为一个 `_consume(_client.generateResponse(_messages))`；seed 分支、`stopGeneration` 的双路调用全删（只 `_client.stop()`）
- 降级逻辑保留：`TimeoutException` → 超时文案；错误且 AI 消息为空 → Mock 降级。判断不再看 `_mode`，只看异常类型与内容状态

## 5. 范围外（明确不做）

- **②的 goals 发送**：只在 `CloudChatClient.initialize` 暂存，不进请求体
- 服务端任何改动
- `StrategistExtractor` / strategy_brief 链路
- Mock 回复策略（`_generateMockResponse` 保留在 Provider）

## 6. 测试策略

| 对象 | 方式 |
|---|---|
| ConversationStrategy | 纯 Dart 单测：去重阈值/滚动窗口、提示词含/不含 goals |
| LocalChatClient | llama 是 FFI 不可 fake —— session 交互收敛到窄接口 `Session`（createChat/addUser/addAssistant/generate/dispose 的最小抽象），用 fake Session 测：diff 增量 append、消费条数推进、去重改写仅 session 侧、75% 截断重建 |
| CloudChatClient | 现有 3 测（真 HttpServer）迁移到新签名 + 新增：round==0 过滤、10 条窗口截取断言 |
| ChatProvider | fake ChatClient 注入：流式缓冲、stopGeneration 半截保留、超时/空内容降级、消息持久化 |
| 回归 | `flutter analyze` 0/0/0 + 全量 `flutter test`（含既有 markdown/sse/cloud 41+ 测试） |

## 7. 风险与等价性检查

- **恢复会话语义**：本地 `seedHistory` 会把欢迎语 seed 进 session——diff 方案初始消费条数为 0，同样会 append 欢迎语，等价 ✅
- **去重 mirror 语义**：`isDuplicate` 重复时不追加 `_recentQuestions.last`，迁移后保持，避免相邻同问反复触发改写
- **`isReady` 语义**：原 StrategistPrompter 恒 true（构造即就绪）；LocalChatClient 保持「initialize 成功即 true」，Provider 的 `!isReady → Mock` 分支不变
- **停止生成**：本地流式被 Provider 取消订阅后，client 侧 buffer/mirror 已写入的 assistant 轮仍会完整登记（原逻辑：catch 外登记 fullReply——迁移时保持「取消即停止写入 session」还是「仍登记已生成部分」需在实现时对齐现状：原实现 `await for` 被取消时 generateResponse 的 for-await 抛 CancelledException… 注意：现状取消订阅时 llama 侧 token 流也被弃，session 未登记 assistant 轮。**迁移保持现状**：取消即不登记）
