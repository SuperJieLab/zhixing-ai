# 端侧 KV 复用可行性备忘

> 日期：2026-09-11
> 状态：**§1–§9 暂不实施（登记为后续候选）**；**§10 已实施**（无状态重放，2026-09-11 落地）
> 触发：用户质疑「本地能不能我们自己去用它的这套 EngineSession 来去实现 KV Cache 的复用」
> 范围：§1–§9 = KV 复用可行性（**暂不采纳**）；**§10 = 端侧「第二真值源」问题**（同源议题——两者都源于 `EngineChat` 自持 `_messages`，**已实施无状态重放**）；**§11 = 业界职责归属对照**（公开资料调研）
> 实施记录：`docs/plans/2026-09-11-local-stateless-replay-{design,plan}.md`
> 关联：`lib/features/chat/engine/client/local_chat_client.dart`、`.workbuddy/memory/2026-09-11.md`

## 1. 问题

端侧每轮推理都要把「人设 + 历史 + 本轮问题」整条 prompt 重新喂给模型。这些内容上一轮已经算过一次，理论上可以复用 Bottom 层的 KV cache 省掉重复计算。包提供了一个便捷层 `EngineChat`（我们正用），但它主动放弃了这件事。问题：**我们能不能绕开它、自己接管来拿到这个提速？**

## 2. 事实基线（源码证据）

`llama_cpp_dart` 为 git 依赖，源码在
`~/.pub-cache/git/llama_cpp_dart-1a8c7563cb5382e23bcd20dc5720fc8d8099ec58/`。

**当下的真实行为**：我们走 chat 路径，每轮清空 + 全量重算。

```dart
// worker.dart:347-353（_runGenerateChat）
final prompt = ChatTemplate.apply(template: template, messages: cmd.messages, addAssistant: true);
session.clear();                                  // KV + token history 清空
session.appendText(prompt, addSpecial: false);    // 从头 append 整条 prompt
```

包作者在 `EngineChat` 类注释里写得很直白（`engine.dart:668-669`）：
> The underlying session's KV cache is cleared at the start of each turn — **incremental KV reuse across turns is a future optimization.**

**能力本身存在，只是没走这条路**——全部已公开导出（`lib/llama_cpp_dart.dart`）：

| 层 | 关键能力 | 对 KV 的意义 |
|---|---|---|
| `LlamaSession`（`session/session.dart`，导出 :66） | `_kvHead` 游标；`generate()` 只 prefill `_tokens.sublist(_kvHead)`（:82-91）；`shiftContext()`（:144）上下文滑动；`captureRawState`/`restoreRawState`（:200/:255）KV 快照落盘 | **默认就是增量 prefill** |
| `EngineSession`（`engine.dart:555`，导出 :39） | `append()`（只推进历史不生成，:564）、`generate(prompt: null)`（从已有历史续生成，:597）、`clear()`、`saveState`/`loadState` | raw 路径 **不清 KV** |
| `ChatTemplate`（`chat/chat_template.dart`，导出 :10） | `fromModel(model)`、`apply({template, messages, addAssistant})` | 模板渲染可自行调用 |
| worker raw 路径 | `_runGenerate`（`worker.dart:271-289`）：有 prompt 时**只** `session.appendText`，**无 `clear()`** | 增量链路是通的 |

`_streamSessionGenerate`（`worker.dart:809-838`）直调 `session.generate(...)`，即上面的增量实现。

## 3. 三条硬约束

### ① 前缀必须逐 token 一致

增量只 prefill `_kvHead` 之后的 token，隐含前提是「会话里已有 token 序列 == 新 prompt 的前缀」。

但 `EngineChat.commitReply()`（`engine.dart:758-762`）登记的是**含 `<think>` 的原始回复**，而我们 DB 存的是 **`stripThinkTags` 之后**的版本 → 两侧 token 不同。

⇒ **不能靠「重放消息列表」实现增量**，只能自己管 append 的内容与边界。
⇒ 边界细节：「上一轮 assistant 的 `<|im_end|>` 是否已在 tokens 里」取决于生成器对 stop token 的处理方式——**必须实测，不可推断**。

### ② KV 缓存独占性（**潜在真 bug，独立于本议题**）

`LlamaEngine.createChat({int seqId = 0})` → `createSession(seqId: seqId)` → worker 里
`state.sessions[sessionId] = LlamaSession(state.context, seqId: cmd.seqId)`（`worker.dart:147-148`）。

**多个 session 可以共用同一个 seqId，即共用同一块 KV slot。** 而：
- `LlamaSummarizer`：`local_context_policy.dart:36` → `engine.createChat()`
- `StrategistExtractor`：`strategist_extractor.dart:100` → `engine.createChat()`

二者都用**默认 `seqId = 0`**，与主会话同槽。

- **今天无害**：每轮都 `clear()`，谁用都是临时占用，用完即弃。
- **一旦改成持久 KV 复用**：摘要器/提取器一跑就**冲掉主会话的缓存**（轻则退化为全量重算，重则前缀错配导致输出异常）。

⇒ 若实施，必须：给它们分配**独立 seqId**（要求引擎 `nSeqMax > 1`），或**严格串行 + 事后重建**。

### ③ 缓存会持续累积 → 更快顶到上下文上限

- 现在：每轮 `clear()`，缓存只需装下**一轮** prompt（受 `localInputBudget = 1668` 约束）。
- 持久 KV：历史 + **全部历史生成回复**（每轮最多 2048 token）都留在缓存里累积，会更快撞上 `nCtx = 4096`。

⇒ **KV 复用不会减少上下文管理的需求，反而放大它。**

## 4. 与上下文压缩的耦合（关键结论）

KV cache 是**前缀缓存**——只认「从头逐字相同」。而我们的压缩是「逐出前端消息 + 把摘要卡插到最前」，**必然改写前缀 → 缓存立即失效 → 只能 clear + 重建**。

因此二者不是二选一，而是**同一个事件的两面**：

- **两次压缩之间**才谈得上 KV 复用（期间是纯 append，前缀稳定）；
- **压缩事件本身就是缓存重建点**——恰好对应已有的 `AssembledContext.evicted` 语义，无需新造概念。

另一条路线是 `shiftContext(auto)`（`ContextShiftPolicy.auto`）：直接滑 KV、丢弃中间 token（llama-server 那套），**完全不动消息列表**。但它**不产生摘要**，与摘要卡方案**不兼容** → 与压缩是**替代关系**，不是叠加。

## 5. 收益评估

省的是**每轮对「人设 + 历史」的重复 prefill**（影响首 token 延迟 TTFT）。
生成部分（≤ `localMaxTokens` 2048 token）不变。

- 最稳定的收益是**人设那几百 token**——现在每轮都白算一遍。
- 短回答场景：prefill 在总延迟中占比明显 → 收益可感。
- 长回答场景：生成阶段主导 → 收益基本可忽略。

**值不值必须真机测，不可拍脑袋。**

**代价**：`EngineChat` 已经帮我们踩平的坑要重做一遍——模板渲染、多轮边界与 stop/special token、错误语义（如 context full 的抛出形态）、消息列表管理。当前为省「每轮一次 prefill」而背这套复杂度，性价比存疑。

## 6. 若将来实施：三条路径

| 路径 | 做法 | 代价 |
|---|---|---|
| A. 自管 `EngineSession` | 不用 `EngineChat`，自己 append 增量、自己渲染模板 | 重做便捷层职责；收益最完整（真正增量） |
| B. `shiftContext(auto)` | 保留 `EngineChat` 语义或改 raw，靠滑动丢中间 token | 不动消息列表，但**不产摘要**，与现有压缩方案冲突 |
| C. 上游 | 给包提 PR 实现 `EngineChat` 跨轮增量（作者已标为 future optimization），或换用已实现 KV 复用的库 | 不受我们控制，周期长 |

## 7. 若将来验证：spike 方案（最小步骤）

不动生产代码，写独立脚本：

1. `spawn` 引擎 → `createSession()`（注意用**独占 seqId**，避免 ② 的干扰）；
2. 第一轮：`append(render(turn1))` → `generate()` → 记录 `kvHead` / `tokenCount` / 首 token 耗时；
3. 第二轮：`append(render(turn2_delta))` → `generate()` → 再记录；
4. **判据**：第二轮 `kvHead` 起始值 > 0 且 ≈ 第一轮结束值 → 增量成立（而非归零重算）；
5. 对照组：同一模型走 `EngineChat` 路径，比较两轮的 TTFT。

**先验证 ①（前缀/token 边界）与收益量级，再决定是否动架构。**

## 8. 附带发现（独立于本议题）

- **② 的 seqId 共用**：无论是否采纳 KV 复用，都建议单独做掉——成本极低，消除一颗定时炸弹。
- **`local_chat_client.dart` 的「增量补差 vs 整体重建」复杂度**：既然底层每轮必 clear + 全量 re-prefill，该分支的**唯一实际收益 = 省一次 `EngineChat` 重建**（一次 worker RPC + 重塞消息），与 prefill 算力无关。是否值得维持 `_consumed` 游标 + `_skipNextHistoryAi` + 双分支 → **已完成评估（§10）并已落地实施：值得删，改为无状态重放**。

## 9. 补充：EngineChat 为什么自己不做增量（设计取舍）

源码里**只有一句**说明（`engine.dart:668-669`，作者标注为 future optimization），**没有写理由**。以下是按结构推断的取舍分析，非作者原话：

**① 它把两种状态拆开了。** 会话状态（`_messages`，跨轮累积、是唯一真相源）保留；计算状态（KV cache）每轮 `clear()` 丢弃。带来的性质是：**每轮输出 ≈ `f(消息列表, 模型参数)` 的纯函数**——与上一轮算过什么无关。

**② 这个性质是它的核心卖点，且我们正在依赖它。**
- 消息列表可以被**任意改写**：`clearHistory()`、删中间某条、换 system、插 few-shot → 下一轮自动生效，无需跟 SDK 协商。
- 我们的压缩/摘要卡（`AssembledContext.evicted`）正是「改写消息列表」。EngineChat 的「变了就重算」让我们不需要处理任何缓存一致性问题。
- 代价是每轮全量 re-prefill，换掉的是**「缓存与消息列表不一致」这一整类 bug**。

**③ 它仍然持有一个 `EngineSession`，但复用的是「槽位」不是「内容」。** `EngineChat._session` 是 final，`createChat()` 时建一次（`engine.dart:672`）；`ClearSessionCommand` → `session.clear()`（`worker.dart:172-182`）把 `_tokens` 与 KV 一并清空 —— 所以**每轮结束后该 session 内部也是空的**。复用对象省的是「一次注册/注销往返」（`createSession` 会 `_nextSessionId++` 并注册进 worker 的 `state.sessions`），不是算力。⇒「复用了 session」与「没复用 KV」不矛盾，是两件事。

**④ 为什么不利用 `EngineSession` 的增量能力（推断，需 spike 验证）**
- **文本 ↔ token 往返不保证逐位一致**：上一轮真正写进 KV 的是**采样出的 token id**，而 `EngineChat` 存的是**解码后的字符串**（`ChatMessage.assistant(replyBuf.toString())`，`engine.dart:761`），下一轮靠**重新渲染 + 重新 encode** 复现前缀。若 `encode(decode(ids)) != ids`（重复空白、特殊字符、多字节边界等），KV 里会残留**非本轮 prompt 前缀**的内容 → 输出静默劣化、**不报错**，极难排查。
  - ⇒ 这一条是 EngineChat 走增量最硬的障碍，**但它是推断，必须实测**（见 §7 spike 第 4 步）。
  - ⇒ 对比：`EngineSession` raw 路径没这个问题，因为它的 token 历史**从头到尾都是自己 append 的，从不做 decode→encode 往返**。谁能管住 token 边界，谁才能用增量。
- **`addAssistant: true` 的收尾形状要对齐**：渲染会额外补一个 assistant 起始头引导生成（`chat_template.dart:61-69`）；上轮 KV 尾巴是「采样出的 token」，下轮渲染尾巴是「文本 + 模板结尾 + 又一个 assistant 头」。要逐 token 对齐等于把模板语义重实现一遍。
- **`shiftPolicy` 会直接动 KV 与 token 列表**（`session.dart:105-114`），前缀本就变形。

**一句话**：`EngineChat` 是为「消息列表是唯一真相源」买单——代价每轮重算，换来可编辑、可重现、无缓存一致性 bug。`LlamaSession` 的增量属于**另一条路的契约**。

## 10. 补充：端侧「第二真值源」问题（消息列表漂移）

> 触发：用户追问「我们业务层的这个 `ChatSession` 到底有没有必要 / 引擎自动登记的回复会不会和我方上下文不一致」
> 状态：**待决策**（本次仅登记，不改代码）

### 10.1 现象：同一轮对话存在两份 AI 回复版本

`EngineChat` 自持 `_messages`（`engine.dart:673`），`createChat()` 时为空，此后**只增不减**（除非显式 `clearHistory()`）：

| 时刻 | 引擎内 `_messages` | 我方（装配结果 / DB） |
|---|---|---|
| 生成收尾 | **自动** `add(ChatMessage.assistant(replyBuf.toString()))` | `stripThinkTags` 后的正文入库 |

`commitReply()`（`engine.dart:758-762`）在**三条路径**上都会触发：`DoneEvent`（:782）、流自然结束无 Done（:788）、`catch` 后 rethrow（:790）。`replyBuf` 累积的是 `TokenEvent.text`（:774）与 `DoneEvent.trailingText`（:780）——**未经 strip 的原文**。

而 `_skipNextHistoryAi`（`local_chat_client.dart:95-100`、`172-177`）的设计是「底层已登记 → 我方不再 add」，因此**引擎里那条恒为含 think 原文，且永远不会被 strip 版本覆盖**。

⇒ 只要本轮产生 think 段（本地 Qwen3 默认思考模式），**两条列表在 assistant 条目上必然分叉**。

### 10.2 三条漂移通道

| # | 通道 | 方向 |
|---|---|---|
| 1 | think 原文 vs strip 正文（主通道） | 引擎内容更长 |
| 2 | `_skipNextHistoryAi` 使引擎版本无机会被覆盖 | 引擎保留旧版本 |
| 3 | `DoneEvent.trailingText` 被引擎登记（`engine.dart:780-781`），但我方 `LlamaChatSession.generate` 只转发 `TokenEvent`（`local_chat_client.dart:57-59`） | 引擎有、我方无（`event.dart:81-83` 注释称 usually empty，概率低） |

### 10.3 四项代价

| # | 代价 | 说明 |
|---|---|---|
| 1 | **token 预算系统性偏低** | `LlamaTemplateEstimator` 估的是 strip 后内容（`localInputBudget = 1668`），实际 prefill 含 think 原文 → 缺口隐形 → 这是 `context full`（真实异常，非估算）的成因之一 |
| 2 | **压缩导致上下文语义跳变** | 走 `_rebuildSession`（`evicted = true`）时全量重塞 strip 版 → 引擎内该条从「含 think」突变「纯正文」；模型看到的上一轮自己的回复，压缩前后不是同一份文本 |
| 3 | **`_skipNextHistoryAi` 是位置型补丁** | 正确性依赖「desired 中首条未消费 AI 即引擎刚登记那条」的**索引对齐假设**；任何偏移（未来插工具消息 / generate 前取消）→ **静默错位**（不崩，上下文悄悄多一条或少一条） |
| 4 | trailingText 缺失 | 见 10.2 #3；概率低，与 1/2 同源 |

（已核查的安全项：`session == null` 早退路径位于 `local_chat_client.dart:147-151`、在 `try` 之外 → **不走 `finally`**，其伪造提示语未被 `_skipNextHistoryAi` 误伤。）

### 10.4 根因与解法

**根因不是「必须 diff」，而是「让引擎持有了权威副本」。** `EngineChat` 的 API 形状（append-only + 自动登记）诱导出「我方维护镜像 + 找 diff 对齐」的结构，但这不是 SDK 的强制要求：`addSystem` / `addUser` / `addAssistant` / `clearHistory` 全是纯本地 List 操作、**零 RPC**（`engine.dart:688-735`），每轮唯一 RPC 是 `generate()`（`:765`）。

对照组：云端 HTTP 无状态、每轮现拼现发，**天然不存在这份隐式状态**，故无任何同步问题。端侧现状 = 「比云端多一个不受控的第二真值源」。

**解法：无状态重放** —— 每轮 `clearHistory()` → `addSystem(人设)` → 可选摘要卡 → 重放 `assemble()` 结果 → `generate()`。**已于 2026-09-11 实施**（见下表「实施结果」列）。

| 项 | 变化 | 实施结果 |
|---|---|---|
| 引擎内列表 | = 装配结果，**逐字一致**（10.2 三通道 + 10.3 四代价全消） | ✅ `LocalChatClient._syncSession` |
| 删除的复杂度 | `_consumed` 游标、`_skipNextHistoryAi` + `finally` 置位、`evicted` 双分支、`_rebuildSession` 的 `dispose + createSession` | ✅ 另移除 `AssembledContext.evicted` 字段（消费方消失） |
| 新增成本 | N 次本地 `List.add`（≈0）；每轮 `generate()` 的 RPC 次数不变 | ✅ 新增 `ChatSession.clear()`（1 行转发） |
| 行为变更 | 模型不再看到自己上一轮的 think 过程 —— **与云端对齐**（云端本就只发 strip 后历史），口径上属修正 | ✅ 附随修复 `DoneEvent.trailingText` 被丢弃（抽 `eventsToText` 纯函数） |
| 影响面 | `local_chat_client.dart` 主逻辑 + 其 **17 条**单测（依赖 skip 语义的用例需改写） | ✅ 7 条改写（3 条语义反转）+ 新增重放不变量与 `eventsToText` 用例；全量 177 用例绿 |

**实施中新发现的坑（重要）**：尾部用户消息的去重改写走 `ConversationStrategy.isDuplicate`，而它**有状态**（会把新问题记入滚动窗口）——同一内容连续判定两次，第二次因 `_recentQuestions.last == trimmed` 直接返回 `true`。而 `context full` 自愈会在同一次 `generateResponse` 内**二次装配 + 二次重放**，若不加约束，同一尾问会被误改写为「请从不同的角度回答…」。解法：`_syncSession` 增加 `nudgeTail` 开关，自愈路径传 `false`（本轮已判定过，不得重复计入）。

### 10.5 顺带的语义澄清

- `ChatSession` 不是「上下文装配层」（装配在 `ContextPolicy`），也不是「SDK 强制要求的适配层」（见 10.4）。其**唯一真实价值 = `LocalChatClient` 单测的 fake 注入点**（否则 17 条用例都需真机加载 2B 模型）。`LlamaChatSession` 6 个方法中 **5 个纯转发**，仅 `generate` 有内容（采样参数收口 + `GenerationEvent` → `String` 收敛）。
- 采纳 10.4 时 `ChatSession` 已**保留**，注释已改写定位：开头明确写「它是本类唯一的 SDK 依赖点 + 可替换依赖的端口（测试接缝）」，并声明「不是 SDK 强制要求的适配层」。新增的 `clear()` 也补了「零 RPC + 每轮开头调用」的说明。
- 改造后 `ChatSession` 的接口形状回到最朴素的「列表 + 生成」：`clear / addSystem / addUser / addAssistant / generate / dispose`。

## 11. 业界对照：列表与缓存的职责归属（公开资料调研，非源码核实）

> 触发：用户提问「其他 Agent 一般怎么处理上下文管理？我们是不是该找一个天然无状态的入口？」
> 来源：Web 检索（Ollama 文档/实践文章、llama.cpp server 机制文章、llama-cpp-python 文档、`llama_cpp_ex` ADR）。**性质为公开资料，非一手源码核实**，结论方向可信、细节以官方文档为准。

### 11.1 共识：**列表归调用方，缓存归后端**（两个正交维度）

| 系统 | 消息列表归谁 | KV 缓存归谁 |
|---|---|---|
| OpenAI 等云 API | 调用方，每次全量发 | 服务端前缀缓存 |
| Ollama | 调用方，每次全量发 | 服务端前缀缓存 |
| llama.cpp `llama-server` | 调用方，每次全量发 | slot，token 级 LCP |
| llama-cpp-python | 应用侧，每次传参 | 无复用，每轮重算 |
| **`llama_cpp_dart`（我们）** | **SDK 内部 `EngineChat`** | 每轮清空，无复用 |

**没有例外**：所有方案都把「消息列表」交给调用方，把「缓存」留给后端，两者绝不混在同一个对象里。

### 11.2 三条一手口径

1. **Ollama 明确无状态**：官方定位是「the chat endpoint itself is stateless so the full context need to be provided」；实践文章反复强调「The Ollama server keeps no conversation state, so your application must resend the complete messages array on every request」。超窗口时的官方建议：**应用侧**丢弃最旧消息对或替换为摘要。
2. **llama.cpp server**：HTTP 请求无状态；服务端靠 **slot** 做前缀复用——slot 保存「完整 token 历史（prompt + 生成 token）」，新请求到达时算 `common_prefix_length(new_tokens, cached_tokens)`，命中部分 `memory_seq_rm(ctx, seq_id, n_match, -1)` 只裁掉不匹配的后缀（`--cache-prompt` / `--cache-reuse`）。关键：**比对发生在 token 层，不是"重放字符串再 encode"**。
3. **llama-cpp-python**：`llm.create_chat_completion(messages=[...])` 是**无状态函数**，messages 是入参；社区标准写法是应用侧维护 `conversation_history` 列表、每次传全量、自行截断。

### 11.3 对本项目 §10 的含义

- **`ContextPolicy` 的方向与业界完全一致** —— 业界把「超窗口怎么办」归为应用层职责（截断 / 摘要），正是我们在做的事。抽象没错。
- **唯一跑偏点是「SDK 内部持了列表」** —— 这是 `llama_cpp_dart` 相对生态主流的设计选择（把无状态函数包成了有状态对象），不是我们引入的。
- **修法不是弃用 `EngineChat`**：SDK **没有**天然无状态入口（公开导出只有 `EngineChat` 与 `EngineSession`，前者的 `add*` 有状态、后者是 token 级会话；`_generate` / `_generateChat` 均为私有）。而 `clearHistory()` + 重放能**构造出**无状态语义，成本≈0，等价于 llama-cpp-python 的「每次传全量」。⇒ **把它当无状态执行器用，而不是换掉它**。
- **（2026-09-11 已落地）** 端侧与 Ollama / llama-cpp-python 的模型完全对齐：`ChatClient.generateResponse(List<ChatMessage> history)` 现在是**真无状态调用**，唯一真相源在 `ChatProvider._messages`。

### 11.4 对本项目 §1–§9（KV 复用）的含义

- **外部印证 §9④ 的推断**：llama.cpp server 的前缀复用是 **token 级 LCP**，从不做「解码字符串 → 重新 encode」的往返。这独立支持了「`EngineChat` 走增量最硬的障碍是文本↔token 往返不可逆」这一判断。
- **收益量级有了参考值**：`llama_cpp_ex` 的 ADR 007 实测（Qwen3-0.6B Q8_0 / Apple M1 Max / 4 轮递增多轮对话）：prefix cache 开启后平均 **487ms vs 597ms ≈ 1.23x**，中位数 1.31x。**收益真实但不是数量级**。
- ⇒ **§1–§9「暂不采纳」的结论不变**，且现在有了量化依据：为 1.2x 级别的 TTFT 改善去背「自管 token 边界 + 独占 seqId + 与压缩强耦合」不划算。
