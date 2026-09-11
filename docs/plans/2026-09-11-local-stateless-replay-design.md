# 知行AI — 端侧会话无状态化（Local Stateless Replay）

> 状态：设计待确认（2026-09-11 对话确认问题成立；用户决策「先落设计与计划文档，代码未动」）
> 前置：`2026-09-11-context-policy-design.md`（ContextPolicy 已落地，Task 1–4 完成）
> 依据：`docs/notes/2026-09-11/local-kv-reuse-feasibility.md` **§10**（问题核实，含源码行号）、**§11**（业界对照）

## 1. 背景与问题

### 1.1 现状：端侧存在两份消息列表

| 列表 | 持有者 | 内容 |
|---|---|---|
| **业务真值** | `ChatProvider._messages`（`chat_provider.dart:47`）→ `ConversationService` 落库 | 完整历史；AI 条目为 `stripThinkTags` 后**正文** |
| **SDK 副本** | `EngineChat._messages`（`engine.dart:673`） | 由 `addSystem/addUser/addAssistant` 累积；且**每轮 `generate` 收尾自动追加回复**（`engine.dart:758-792`，Done / 流自然结束 / catch **三条路径**均触发） |

`LocalChatClient` 用 `_consumed` 游标（`:93`）找 diff 让 SDK 副本追上装配结果，并用 `_skipNextHistoryAi`（`:95-100`）跳过"引擎已自动登记"的那条 AI。

### 1.2 三条漂移通道（同一条回复，两处内容不同）

| # | 通道 | 方向 |
|---|---|---|
| 1 | 引擎登记 `replyBuf`（**含 think 原文**，`:761`）vs 我方存 strip 后正文 | 引擎内容更长 |
| 2 | `_skipNextHistoryAi` 使引擎版本无机会被覆盖 | 引擎保留旧版本 |
| 3 | `DoneEvent.trailingText` 被引擎登记（`:780-781`），但 `LlamaChatSession.generate` 只转发 `TokenEvent`（`local_chat_client.dart:57-59`） | 引擎有、我方无（`event.dart:81-83`，usually empty） |

⇒ 只要本轮产生 think 段（本地 Qwen3 默认思考模式），两条列表在 assistant 条目上**必然分叉**。

### 1.3 四项代价

| # | 代价 | 说明 |
|---|---|---|
| 1 | **token 预算系统性偏低** | `LlamaTemplateEstimator` 估的是 strip 后内容（`localInputBudget = 1668`），实际 prefill 含 think 原文 → 缺口隐形 → 这是 `context full`（真实异常）的成因之一 |
| 2 | **压缩导致语义跳变** | 走 `_rebuildSession`（`evicted = true`）时全量重塞 strip 版 → 引擎内该条从「含 think」突变「纯正文」；模型看到的上一轮自己的回复，压缩前后不是同一份文本 |
| 3 | **位置型补丁脆弱** | `_skipNextHistoryAi` 的正确性依赖「desired 中首条未消费 AI 即引擎刚登记那条」的**索引对齐假设**；任何偏移（未来插工具消息 / generate 前取消）→ 静默错位（不崩，上下文悄悄多一条或少一条） |
| 4 | trailingText 缺失 | 见 §1.2 #3 |

（安全项已核：`session == null` 早退路径在 `local_chat_client.dart:147-151`、位于 `try` 之外 → 不走 `finally`，其伪造提示语未被 `_skipNextHistoryAi` 误伤。）

### 1.4 根因

**不是「必须 diff」，而是「让引擎持有了权威副本」。**

`EngineChat` 的 API 形状（append-only + 自动登记）诱导出「我方维护镜像 + 找 diff 对齐」的结构，但这不是 SDK 的强制要求：`addSystem` / `addUser` / `addAssistant` / `clearHistory` 全是**纯本地 List 操作、零 RPC**（`engine.dart:688-735`），每轮唯一 RPC 是 `generate()`（`:765`）。

业界对照（备忘 §11）：Ollama / llama.cpp `llama-server` / llama-cpp-python **一致**采用「**列表归调用方，缓存归后端**」，两个维度绝不混在同一对象里；只有 `llama_cpp_dart` 把列表收进了 SDK。

## 2. 已确认决策

| 决策点 | 结论 | 依据 |
|---|---|---|
| 是否弃用 `EngineChat` | **不弃用** | SDK 无纯无状态入口：`llama_cpp_dart.dart:39` 仅导出 `EngineChat/EngineSession/LlamaEngine`，`_generate`（`engine.dart:388`）与 `_generateChat`（`:415`）**均私有** |
| 会话用法 | **降级为无状态执行器**：每轮 `clearHistory()` + 重放装配结果 | 等价于 llama-cpp-python「每次传全量 messages」、Ollama「每次重发完整数组」 |
| 是否降级到 `EngineSession` | **不** | 需自管模板渲染 / stop token 边界 / 错误语义（备忘 §5 列出的坑），为省一次 `clearHistory()` 不划算 |
| 是否自管 KV cache | **不** | 沿用备忘 §1–§9 结论；§11.4 补上量化依据（prefix cache 实测 1.23x，非数量级） |
| 是否保留 `ChatSession` | **保留** | 唯一价值 = 单测 fake 注入点（否则 17 条用例需真机加载 2B 模型）；但注释须把定位写准 |
| 唯一真相源 | `ChatProvider._messages` | 双端一致 |

## 3. 目标语义与不变量

每轮 `generateResponse(history)` 的会话同步：

```
session.clear()                       // 清空 SDK 侧消息列表（零 RPC）
session.addSystem(persona)            // 人设唯一出处不变
[可选] session.addSystem(summaryCard) // 摘要卡紧随人设
for msg in assembled.messages:        // 按序全量重放
    session.addUser(...) | session.addAssistant(...)
session.generate(...)                 // 每轮唯一 RPC，次数与现状一致
```

**改造后应恒成立的不变量**

| # | 不变量 |
|---|---|
| 1 | `EngineChat._messages` ≡ `persona` + 摘要卡 + `AssembledContext.messages`，**逐字一致** |
| 2 | 引擎内 assistant 条目内容 ≡ Provider 列表中的内容（均为 strip 后正文） |
| 3 | `LocalChatClient` 不持有消息列表（唯一例外：重放时的一次性循环变量） |
| 4 | 不存在位置型补丁——不得再引入类似 `_skipNextHistoryAi` 的索引对齐假设 |

## 4. 接口与代码变化

### 4.1 `ChatSession` 新增 `clear()`

当前接口（`local_chat_client.dart:21-31`）**没有清空能力**，无法重放。新增：

```dart
abstract class ChatSession {
  /// 清空会话侧消息列表（转发 EngineChat.clearHistory，零 RPC）。
  void clear();
  void addSystem(String content);
  void addUser(String content);
  void addAssistant(String content);
  Stream<String> generate({int maxTokens});
  void dispose();
}
```

`LlamaChatSession`：`void clear() => _inner.clearHistory();`（对应 `engine.dart:732`）。

### 4.2 `LocalChatClient` 删除项

| 成员 | 位置 | 理由 |
|---|---|---|
| `_consumed` | `:93` | diff 游标不再需要（每轮全量重放） |
| `_skipNextHistoryAi` | `:95-100` | 位置型补丁；重放后引擎不再领先于我方 |
| `skipFirstAi` / `aiSkipped` | `:153-154`、`:167-177` | 同上 |
| `evicted` 双分支 | `:161-192` | 重放路径唯一，无需分支 |
| `_rebuildSession` 中的 `dispose + createSession` | `:288-291` | 不再新建会话对象，改为 `clear()` + 重放 |

> **⚠️ 不得误删**：`context_policy.dart:209` 的同名 `_consumed` 是 `BaseContextPolicy` 的**纳入游标**（有状态保留窗口机制的一部分，见 context-policy design §4），属设计内，必须保留。

### 4.3 `LocalChatClient` 新形态（要点）

```dart
@override
Stream<String> generateResponse(List<ChatMessage> history) async* {
  final session = _session;
  if (session == null) { /* 未初始化分支不变 */ }

  final assembled = await _policy.assemble(history, systemPrompt: _systemPrompt);
  _syncSession(session, assembled);        // clear + persona + 摘要卡 + 全量重放
  // think 剥离输出逻辑不变；context full 自愈分支改为重新 assemble + _syncSession
}

void _syncSession(ChatSession session, AssembledContext assembled) {
  session.clear();
  session.addSystem(_systemPrompt);
  final card = assembled.summaryCard;
  if (card != null) session.addSystem(card);
  final msgs = assembled.messages;
  for (var i = 0; i < msgs.length; i++) {
    final msg = msgs[i];
    if (msg.content.isEmpty) continue;
    if (msg.role == MessageRole.user) {
      session.addUser(i == msgs.length - 1 && _strategy.isDuplicate(msg.content)
          ? '${msg.content}（请从不同的角度回答，不要重复之前的观点）'
          : msg.content);
    } else {
      session.addAssistant(msg.content);
    }
  }
}
```

**保留不动**：think 剥离流式输出（`:194-244`）、尾部用户消息去重改写判据（`i == msgs.length - 1`）、`context full` 捕获与 `handleOverflow()` 自愈、`isReady` / `initialize` / `dispose` 语义。

### 4.4 生命周期变化

| 时刻 | 现状 | 改造后 |
|---|---|---|
| `initialize()` | `createSession()` + `addSystem(persona)` | **不变** |
| 每轮 | 增量 append；`evicted` 时 dispose + createSession | `clear()` + 重放（**不再 create/dispose**） |
| `dispose()` | `session.dispose()` | **不变** |

⇒ 全生命周期只存在**一个** `ChatSession` 实例（`initialize` 创建）。

## 5. 与既有设计的关系

| 既有设计 | 影响 |
|---|---|
| `ContextPolicy` 抽象 | **不变**。装配职责、过滤/装窗/压缩算法、`BaseContextPolicy` 有状态保留窗口全部保留 |
| `AssembledContext.evicted` | **消费方消失**（原唯一消费方是 `LocalChatClient:161`）→ 建议清理，见 plan Task 3 |
| `PackResult.evicted`（List） | 不变。仍是 `BaseContextPolicy` 内部触发摘要器的判据（`context_policy.dart:267`） |
| `BaseContextPolicy._consumed` | 不变（与 client 的同名成员是两回事，见 §4.2） |
| `ChatClient` 接口 | 不变。`generateResponse(List<ChatMessage> history)` 签名与语义**反而更纯粹**（真正成为无状态调用） |
| 云端 `CloudChatClient` | **不变**。它本来就是无状态（每轮现拼现发）——本次改造后**端侧与云端同构** |
| `ChatProvider` | **不变**。真值源与调用方式均不动 |
| 备忘 §1–§9（KV 复用） | 不受影响，结论仍为「暂不采纳」 |

## 6. 边界与红线

| 事项 | 归属 | 说明 |
|---|---|---|
| 消息列表真相源 | `ChatProvider._messages` | client 不持（不变量 3） |
| 上下文装配 | `ContextPolicy` | 本次不动 |
| 会话同步（重放） | `LocalChatClient._syncSession` | 唯一的 SDK 交互点 |
| think 剥离 | `LocalChatClient` 输出侧 | 上下文用 strip 后内容——改造后**引擎与我方一致** |
| SDK 概念 | 仅限 `LlamaChatSession` 内 | 不得外泄 `EngineChat` 到 provider / policy |

**新增红线**：不得再引入任何依赖「引擎内部状态与我方索引对齐」的机制（不变量 4）。

## 7. 行为变更（用户可见）

| # | 变更 | 影响评估 |
|---|---|---|
| 1 | 模型**不再看到自己上一轮的 think 过程** | 与云端对齐（云端本就只发 strip 后历史）；符合 Qwen3 官方模板对 assistant 历史消息的处理惯例。需冒烟观察多轮连贯性 |
| 2 | token 预算**变准**（不再有隐形 think 占用） | 压缩触发点后移 → 长对话中压缩发生得更晚；`context full` 异常应显著减少 |
| 3 | 上下文中历史回复内容变化（strip 版覆盖原含 think 版） | 回复风格可能有轻微变化，属预期 |
| 4 | 取消 / 失败轮的 AI 内容，下一轮改为**按 Provider 存的文本重放** | 此前是「跳过、让引擎保留自动登记的版本」；现在完全以业务列表为准（语义更正确） |

## 8. 测试策略

| 对象 | 方式 |
|---|---|
| 重放不变量（新） | fake session：断言每轮 `ops` 为 `[system…, user…, assistant…, generate…]` **全量**序列，且 `clear` 首现 |
| 现有 17 用例 | 逐一核对；**7 条需改写**（其中 3 条语义反转） |
| 会话实例数 | 断言全生命周期 `factory.created.length == 1`（不再重建） |
| 去重改写 | 仍在重放时对尾部用户消息生效 |
| think 剥离 / 溢出自愈 / dispose / 构造校验 | 语义不变，用例保留 |
| 回归 | 全量 `flutter test`（当前 175 用例基线）+ `flutter analyze` 0 |

**需改写的 7 条用例**（`local_chat_client_test.dart`）：

| 行 | 用例 | 变化 |
|---|---|---|
| `:152` | 首轮：合格消息入会话，**回复由引擎登记** | 断言改为不依赖"引擎登记" |
| `:177` | **二次调用只 append 新增（不重放已消费消息）** | **语义反转** → 二次调用全量重放 |
| `:222` | 压缩：超预算时**装窗重建** | 断言语言改为"重放"（不再 dispose+create） |
| `:302` | 消息数不超过保底：不触发压缩（**不重建**） | 同上 |
| `:361` | 取消：客户端不登记半截回复，**下一轮 diff 跳过** | **语义反转** → 下一轮重放该条 |
| `:397` | 生成失败：**下一轮 diff 跳过** | **语义反转** → 同上 |
| `:430` | context-full 自愈：**强制重建**只留最后 4 条 | 改为"重放最后 4 条" |

## 9. 风险

- **行为变更需真机冒烟**：变更 1/2 是语义级调整，单测无法覆盖"模型表现"——列为 Task 4 冒烟项。
- **测试改写面**：7/17 用例需动，其中 3 条语义反转；改写时**不得**为了"让测试过"而妥协不变量（不变量 1 需新增正向断言）。
- **与未验证变更混合**：工作区已有未提交改动（更名 / 重复登记修复 / 文档）。建议**先固化再开工**，避免混淆回退点。
- **future 风险**：若将来 SDK 提供「设置整份列表」入口，本方案的 `_syncSession` 可进一步简化为一次调用——但这不影响当前设计成立。

## 10. 范围外（明确不做）

- 端侧 KV cache 复用 / 自管 token 会话（备忘 §1–§9，已结论「暂不采纳」）
- `seqId` 独占隔离（备忘 §3② 的独立潜在问题，建议单独立项）
- `EngineSession` raw 路径迁移（§2 已否决）
- 云端任何改动（本就无状态）
- 上下文压缩策略本身的调整（`ContextPolicy` 不动）
- `ChatSession` / `LlamaChatSession` 的**更名**（用户已明确本轮不动名字）
