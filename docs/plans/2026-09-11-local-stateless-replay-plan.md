# 知行AI — 端侧会话无状态化实施计划

> 状态：**✅ 已完成**（2026-09-11 全部 Task 落地；`flutter analyze` 0，全量 `flutter test` 177 绿）
> 设计：`docs/plans/2026-09-11-local-stateless-replay-design.md`
> 依据：`docs/notes/2026-09-11/local-kv-reuse-feasibility.md` §10（问题与源码证据）、§11（业界对照）
> 前置纪律：工作区已有未提交改动（`local_chat_client.dart` 更名/重复登记修复、`local_chat_client_test.dart`、`docs/PROJECT.md`、`docs/notes/2026-09-11/`）。**开工前先提交，固化回退点**，避免与本次语义级改动混淆。→ ✅ 已提交 `1d16811`
> 提交纪律：每 Task 实现 → 自查 → 全量回归 → 改动留工作区，由用户确认后提交（不自动 commit）
> 测试命令（宿主代理会拦截 flutter_tester，须一并清 ALL_PROXY）：
> `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u ALL_PROXY -u all_proxy NO_PROXY='*' no_proxy='*' flutter test`
>
> **实施补充（计划外的必要决定）**：新增 `_syncSession(nudgeTail:)` 开关。`ConversationStrategy.isDuplicate` **有状态**（会把新问题记入滚动窗口），而 `context full` 自愈在同一次 `generateResponse` 内二次装配 + 二次重放 → 同一尾问会被二次判定为「重复」而遭误改写。自愈路径传 `nudgeTail: false` 解决（详见备忘 §10.4）。

## Task 1：`ChatSession.clear()` + `LocalChatClient` 无状态重放 ✅ 已完成

**文件**

改 `lib/features/chat/engine/client/local_chat_client.dart`：

1. **接口新增清空能力**（`:21-31`）：
   ```dart
   abstract class ChatSession {
     void clear();   // 新增：清空会话侧消息列表
     ...
   }
   ```
   `LlamaChatSession`：`void clear() => _inner.clearHistory();`（对应 `engine.dart:732`，纯本地操作、零 RPC）。

2. **删除 diff 机制**：
   - `_consumed`（`:93`）、`initialize` 中的 `_consumed = 0`（`:135`）
   - `_skipNextHistoryAi`（`:95-100`）、`initialize` 中的置位（`:136`）、`generateResponse` 中的取值（`:153-154`）、`finally` 中的无条件置位（`:268`）
   - `evicted` 双分支（`:161-192`）整块替换
   - 自愈分支里的 `_consumed = healed.messages.length`（`:258`）

3. **新增 `_syncSession`**（替代原 `_rebuildSession`，并去掉 `dispose + createSession`）：
   ```
   clear() → addSystem(persona) → [addSystem(摘要卡)] → 按序全量重放 assembled.messages
   ```
   重放时保留尾部用户消息去重改写（判据由 `i == desired.length - 1` 改为 `i == msgs.length - 1`）。

4. **`generateResponse` 主路径**：`assemble` → `_syncSession` → 流式生成（think 剥离逻辑原样保留）。

5. **`context full` 自愈**：捕获 → `_policy.handleOverflow()` → 重新 `assemble` → `_syncSession`（不再新建会话）。

6. **文档注释同步**：类注释与 `ChatSession` 注释中"增量补差 / 窗口收缩时整体重建会话 / 省一次 worker RPC"等表述全部过时，按 design §3 的不变量重写。

改 `test/features/chat/engine/client/local_chat_client_test.dart`：
- `_FakeChatSession` 增加 `clear()`（记录为 `ops.add('clear')`）
- 改写 design §8 列出的 **7 条用例**（`:152` / `:177` / `:222` / `:302` / `:361` / `:397` / `:430`），其中 `:177`、`:361`、`:397` 为**语义反转**
- 新增**重放不变量**用例：每轮 `ops` 为 `[clear, system:…, user:…, assistant:…, generate:…]` 全量序列；且 `factory.created.length` 恒为 1
- 评估 `_ChatSessionFactory.tokensForNew` 机制是否还有用（不再重建会话，该字段语义可能失效）

**验证**（全部通过）
- [x] 每轮均以 `clear` 开头，且重放**全量**（非增量）消息
- [x] 全生命周期只创建 **1 个** `ChatSession`（不再 dispose + create）
- [x] 引擎内 assistant 条目 ≡ Provider 列表内容（无 think、无重复登记）——即 design §3 不变量 1/2 有正向断言
- [x] 尾部用户消息去重改写仍生效（仅本轮最后一条）
- [x] think 剥离、`context full` 自愈、`isReady`、`initialize` 失败、`dispose`、构造期校验语义**零回归**
- [x] `flutter analyze` 0；全量 `flutter test` 全绿（基线 175 → **177**）

**实施差异**：`tokensForNew` 已**删除**（不再重建会话，该字段彻底失效）；新增 `nudgeTail` 开关（见头部「实施补充」）。

**⚠️ 行为变更**（详见 design §7）：模型不再看到自身历史 think；预算估算变准（压缩触发点后移）；取消/失败轮改为按业务列表重放。

## Task 2：修复 `DoneEvent.trailingText` 被丢弃 ✅ 已完成

**问题**：`LlamaChatSession.generate`（`local_chat_client.dart:49-60`）只转发 `TokenEvent`，而 `EngineChat` 会把 `DoneEvent.trailingText` 写进 `replyBuf` 并登记（`engine.dart:780-781`）→ 引擎有、我方无（design §1.2 #3）。

**做法**：
- 把「事件流 → 文本流」的转换抽成**顶层纯函数**（如 `Stream<String> eventsToText(Stream<GenerationEvent>)`），`LlamaChatSession.generate` 只负责拼装（注入 sampler / maxTokens）。
  > 必要性：`EngineChat` 是 `final class`，无法 mock；抽成纯函数后可用 `Stream.fromIterable([TokenEvent, DoneEvent])` 直接单测。
- 转换规则：`TokenEvent → event.text`；`DoneEvent` 且 `trailingText.isNotEmpty → yield trailingText`；其余事件忽略。

**文件**：改 `lib/features/chat/engine/client/local_chat_client.dart`；新增用例到 `local_chat_client_test.dart`（或独立纯函数测试文件）。

**验证**（全部通过）
- [x] `DoneEvent.trailingText` 非空时被 yield；为空时不产生空事件
- [x] 与 think 剥离的交互正确（trailing 内容进入 `buffer` 并参与收尾判断）
- [x] `flutter analyze` 0；全量 `flutter test` 绿

**实施差异**：`eventsToText` 定点在 `local_chat_client.dart` 顶层（与 `ChatSession` 同文件，便于把 SDK 依赖收敛在一处）；unit test 落在 `local_chat_client_test.dart` 的 `group('eventsToText')`，共 3 例。

## Task 3：清理 `AssembledContext.evicted` + `ChatSession` 注释定位 ✅ 已完成

> 依赖 Task 1（其唯一消费方是 `LocalChatClient:161`）

**文件**

改 `lib/features/chat/engine/context/context_policy.dart`：
- 移除 `AssembledContext.evicted` 字段（声明 `:20`、构造默认值 `:25`、`toString` `:31`、赋值 `:290`）
- **保留** `PackResult.evicted`（List，`BaseContextPolicy` 内部触发摘要器的判据，`:267`）与 `_consumed`（`:209`，纳入游标）——两者都是设计内机制

改 3 个策略测试（约 7 处断言）：`context_policy_test.dart:337-351`、`local_context_policy_test.dart:86,102`、`cloud_context_policy_test.dart:143,164,178`。

改 `lib/features/chat/engine/client/local_chat_client.dart`：
- `ChatSession` / `LlamaChatSession` 注释补写**存在理由**：它是**可替换依赖的端口（测试接缝）+ SDK 唯一依赖点**，**不是**"SDK 强制要求的适配层"（当前注释 `:12-20` 只写了"它不是 KV 缓存句柄"，未写"它为何存在"，容易被误读）。

**验证**（全部通过）
- [x] `AssembledContext` 不再有 `evicted`；全仓 `grep` 无残留消费方
- [x] 策略层装配行为零变更（仅字段移除）
- [x] `flutter analyze` 0；全量 `flutter test` 绿

**实施差异**：`AssembledContext` 的类注释补写了「为何不再有 `evicted`」（client 恒为无状态重放，无需告知是否收缩）；`BaseContextPolicy` 的类注释中「既避免每轮重建会话」一句随之删除（不再重建）。`context_policy_test.dart` 的 `evicted 标记` 用例整条删除（其余断言已覆盖等价语义）。

## Task 4：收尾 ✅ 已完成

- [x] 全量回归：`flutter analyze` 0 + 全量 `flutter test` 绿（177）
- [x] 文档：
  - `docs/PROJECT.md`：决策表「端侧消息列表真相源」行由**待决策**改为**已采纳**（附实施要点与四条不变量）；「传输层」行描述改为「无状态重放——每轮 `clear()` + 按装配结果全量重放」；目录说明（`local_chat_client.dart` 行）同步
  - `docs/notes/2026-09-11/local-kv-reuse-feasibility.md`：头部状态与 §10.4/§10.5/§11.3 标注已实施；§8「可另开一轮评估」指针更新为已落地
  - `docs/plans/2026-09-11-local-stateless-replay-{design,plan}.md`：状态改为已完成
  - `.workbuddy/memory/MEMORY.md`：对话链路条目更新（「端侧增量补差 vs 重建」→「无状态重放」，并写明不变量）
- [ ] 冒烟项（**用户侧**，需真机/模拟器）— **待用户验证**：
  - 多轮对话连贯性（模型不再看到自身 think 后是否可接受）
  - 长对话压缩触发时机后移是否符合预期
  - `context full` 异常是否显著减少
  - 取消 / 失败轮之后继续对话，上下文正确

## 依赖关系

```
Task 1 ──▶ Task 3 ──┐
Task 2 ─────────────┴──▶ Task 4
```

Task 2 完全独立（同文件不同区域，可先做或后做）；Task 3 依赖 Task 1（消费方消失后才能清理）；Task 4 统一回归与文档。

## 关键实现备忘

- **区分两个 `_consumed`**：`local_chat_client.dart:93`（client 的 diff 游标，**删**）vs `context_policy.dart:209`（`BaseContextPolicy` 纳入游标，**保留**）。误删后者会破坏"有状态保留窗口"（一次压缩后不再每轮触发压缩）。
- **`clear()` 而非重建**：`EngineChat.clearHistory()` 是纯本地 `_messages.clear()`，零 RPC；相比每轮 `createChat()`（`_nextSessionId++` + worker 注册/注销）更省，且不产生会话对象churn。
- **不变量优先于测试通过**：7 条用例需改写，但改写目标是"表达新语义"，不是"迁就旧断言"。新增的不变量断言（引擎列表 ≡ 装配结果）是本 Task 的核心交付。
- **think 剥离位置不变**：仍在输出侧（`stripThinkTags` + 流式状态机）。改造后上下文与显示**天然一致**，不再需要"跳过"来兜。
- **`EngineChat` 是 `final class`**：不可 mock。需要单测的 SDK 交互（如 trailingText 转换）必须抽成纯函数或经 `ChatSession` 端口注入。
- **不做的事**：不迁移到 `EngineSession` raw 路径；不引入 KV 复用；不改 `ContextPolicy` 的装配算法；不改名 `ChatSession`。
