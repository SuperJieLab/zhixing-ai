# 知行AI — 大模型服务分层实施计划

> 状态：**设计已确认 · 待开工**（2026-09-12 三项待拍全部拍定；代码未动）
> 设计：`docs/plans/2026-09-12-llm-service-layering-design.md`
> 依据：`docs/notes/2026-09-11/local-kv-reuse-feasibility.md` §11（业界对照）；`.workbuddy/memory/2026-09-11.md`（架构决策链 + 源码核实）
> 前置纪律：工作区**尚有三份文件未提交**（本 plan / design 两份新文档 + `docs/PROJECT.md` 决策表一行修改；本地领先远端 18 commit）→ 开工前先提交这批文档，形成回退点。
> 提交纪律：每 Task 实现 → 自查 → 全量回归 → 改动留工作区，由用户确认后提交（**不自动 commit**）
> 推进原则：**strangler 式增量**——每 Task 结束时系统必须 `analyze` 0 + 全量测试绿；新路径先并存 → 再切消费方 → 最后删旧路径。
> 反退化纪律：**不得为「让测试过」而妥协 design §8 的不变量**。若不变量与现有测试冲突，先改测试语义并记录理由。
> 测试命令（宿主代理会拦截 flutter_tester，须一并清 ALL_PROXY）：
> `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u ALL_PROXY -u all_proxy NO_PROXY='*' no_proxy='*' flutter test`
> 开工前须拍定：**已全部拍定**——#1（`SettingsRepository` 加窄 `Listenable` + 入口复核）、#4（保留窗口只存游标 `k`，每轮现算）、#6（`askJson`）均于 2026-09-12 拍定，见 design §10.1「已拍定」；#2 / #3 / #5 / #7 / #8 可在对应 Task 内定。**可开工。**

## Task 1：原语下沉（零行为变更）✅ 已完成（2026-09-12）

> **实施记录**：analyze 0 + 全量 177 绿。与计划的两处偏差——① `completeText` 入参取 `EngineChat chat` 而非 `LlamaEngine engine`：把「createChat 失败」的异常语义留给调用方（与平移前两处样板的 try 边界一致，保真零行为变更；摘要器错误照旧回落、提取器 createChat 错误照旧上抛为 error）；② 「摘要器补 trailingText 用例」不可达——`LlamaEngine` / `EngineChat` 均 `final class` 无法 fake，以 `eventsToText` 既有 3 例（含 trailingText）+「事件循环唯一实现」代替，端到端靠 Task 5 冒烟。

**目标**：把三处重复的「原语」搬进 `core/llm/`，消掉重复并**顺带修掉两处 `trailingText` 遗漏 + 统一提取口径**。**不含任何接口/行为变更**——本 Task 的价值是给后面三个 Task 铺好共享底座。

**文件**

1. 新增 `lib/core/llm/inference.dart`
   - `Stream<String> eventsToText(Stream<GenerationEvent> events)`（从 `local_chat_client.dart:41-49` 平移，含 `DoneEvent.trailingText`）
   - `Future<String> completeText(EngineChat chat, {required String system, required String user, SamplerParams? sampler, int? maxTokens, bool stripThink = false})`——即摘要器/提取器那段样板的合并版（流式收完 + finally 释放；见本 Task「实施记录」的入参偏差说明）
2. 新增 `lib/core/llm/context_budget.dart`
   - 平移 `ContextEstimator`（`context_policy.dart:83-93`）、`packTailWithinBudget`（`:117-139`）、`packKeepLast`（`:145-158`）、预算配比（`localInputBudget` 推导的说明）
   - 红线：本文件**不得**依赖 feature；单位无关（token / 字符都由实现决定）
3. 改 `lib/features/chat/engine/context/context_policy.dart`
   - 改为从 `core/llm/context_budget.dart` `export`/import（避免三处定义并存）；装配骨架 `BaseContextPolicy` **本 Task 不动**
4. 改 `lib/features/chat/engine/context/local_context_policy.dart`
   - `LlamaSummarizer.summarize`（`:34-56`）改为 `createChat` + `completeText(..., stripThink: true)` 两行（事件循环与手动 `stripThinkTags` 均由原语内部承担）
5. 改 `lib/features/strategy_brief/engine/strategist_extractor.dart`
   - 单次补全改 `completeText(...)`（删事件循环 `:106-117`）
   - `_truncateMessages`（`:148-166`）删除 → 用 `packTailWithinBudget`
   - 度量改用 `LlamaTemplateEstimator`（`+16/条`）——**口径统一**（design §9.2）
6. 改 `lib/features/chat/engine/client/local_chat_client.dart`
   - `eventsToText` 从本文件移出（import 自 `core/llm/inference.dart`），`LlamaChatSession.generate` 不变

**验证**
- [x] 三处事件循环只剩一份实现（`grep -rn "is TokenEvent" lib` 仅命中 `inference.dart`）
- [x] `_truncateMessages` 已删；提取装箱走共享实现（`packTailWithinBudget`，`minKeep: 0` 保持旧截断语义）
- [x] `trailingText` 在提取器/摘要器路径上也生效（经 `completeText` 统一；**用例不可达**——`LlamaEngine`/`EngineChat` 均 final 无法 fake，以 `eventsToText` 既有 3 例覆盖，端到端靠 Task 5 冒烟）
- [x] 提取预算口径与 chat 侧一致（同一估计器 `LlamaTemplateEstimator`）
- [x] `flutter analyze` 0；全量 `flutter test` 绿（**基线 177**）
- [x] **零行为变更**：除上述口径/尾字符修正外，无逻辑差异

**风险**：`context_budget.dart` 上移会不会让 `ContextEstimator` 的既有 import 大面积改动 → 用 `export` 兜住，避免波及 3 个策略测试。

## Task 2：服务骨架 + 单一模式来源 + 提取改走服务 ⬜ 未开始

> 依赖 Task 1。这是**第一个垂直切片**：修掉 design §1.2 那个真实缺陷（云端模式 + 未下载模型 → 报错）。

**文件**

1. 新增 `lib/core/llm/llm.dart`——业务依赖面：
   ```dart
   abstract class Llm {
     Future<String> ask({required String system, required String user, int? maxTokens});
     bool get isReady;
   }
   ```
   （`converse` 在 Task 3 加；本 Task 只落 `ask` + `isReady`）
2. 新增 `lib/core/llm/llm_service.dart`
   - **唯一的模式解析点**（读 `chatCloudMode` → `ChatMode`；`ChatMode` enum 从 `cloud_chat_client.dart:14` 搬来）
   - `ask` 内部：按模式选后端 → 云端走 BYOK 非流式（**抽取 `CloudSummarizer` 的 Dio POST + `_extractContent`（`cloud_context_policy.dart:67-109`）为共享的云端单次补全**）→ 本地走 `LlamaService.instance.ensureReady(...)` + 本地 `completeText`
   - `askJson`（design §10.1 已拍定 #6）：与 `ask` 同一补全原语，差别只在**输出契约**——施加 JSON-only 约束 → 剥围栏 / 刮第一段 `{...}` → `jsonDecode`；返回 `Map?`（解析不出 → null；请求失败仍抛异常）。容错逻辑**只在这里出现一次**，双后端共用
   - 「确保就绪」是**入口职责**：`ask` 被调用时若后端未就绪则自行确保（本地加载 / 云端校验三件套），失败抛带语义的异常
3. 改 `lib/main.dart`——composition root：构造 `LlmService` → `unawaited(initialize())` → `Provider<Llm>.value(value: llm)`（design §6.3）
4. 改 `lib/features/strategy_brief/providers/strategy_brief_provider.dart`
   - `:142-149` 的 `LlamaService.instance.ensureReady` + `StrategistExtractor(engine)` 改为注入的 `Llm` + `ask`
   - 错误路径 `:174-179` 保留（后端不可用仍是 error，但不再是「模式错配」）
5. 改 `lib/features/strategy_brief/strategy_brief_page.dart`——`context.read<Llm>()` 注入（现 `:23` 直接 `StrategyBriefProvider(widget.conversation)`）
6. 改 `strategist_extractor.dart`——构造改为依赖 `Llm`（或由 provider 直接 `ask`，实施时定）

**验证**
- [ ] `grep -rn "ChatMode" lib/features` **为空**；`grep -rn "chatCloudMode" lib/features` **只命中 `features/settings/`**（不变量 1；设置页必须能**写**模式，故不能要求整体为空——见 design §8 复核记录 R2）
- [ ] `grep -rn "LlamaService\|LlamaEngine" lib/features/strategy_brief` **为空**（不变量 2 的提取部分）
- [ ] `grep -rn "LlmService" lib/features` **为空**（不变量 6）
- [ ] 云端模式 + 未下载本地模型 → 提取走云端，**不再报「需要下载模型」**
- [ ] 本地模式 → 提取行为与改造前一致（含 think 剥离、JSON 解析、`relevant:false` 短路）
- [ ] 新增 `llm_service_test.dart`：模式解析（含三件套未配齐的云端）+ `ask` 两实现（fake）
- [ ] `flutter analyze` 0；全量 `flutter test` 绿

**⚠️ 行为变更**：云端模式下提取会产生 API 调用与费用；BYOK 模型的 JSON 遵从度未知 → 本 Task 必须同时落 design 附录 **A1**（JSON-only 提示词约束 + 刮 `{...}` 容错），否则是降级。

**⚠️ 前置（已解除）**：A1 的落法已拍定 = design §10.1 #6 **方案 A**：本 Task 落的不是「只加提示词约束」，而是 **`askJson`（结构化返回 + 内部容错）**——签名与容错语义见 design §6.1 / §10.1「已拍定」。

**风险**：云端 `ask` 若不加容错，提取成功率可能低于本地。**A1 与本 Task 不可分割**。

## Task 3：对话链路并入服务 ⬜ 未开始

> 依赖 Task 2。**最大的一块**，`features/chat/engine/` 在此解体。建议拆成多个 commit 粒度（交付下沉 / 转换上移 / provider 改造）。

**文件**

1. **交付段下沉**（`ChatClient` → 交付接口）
   - `features/chat/engine/client/` → `core/llm/delivery/`；`ChatClient` 退化为「怎么把装配结果送进模型」
   - `LocalChatClient._syncSession`（清空 + 重放）成为端侧交付实现内部细节；`ChatSession` / `ChatSessionFactory` 测试接缝随之下沉
   - `CloudChatClient` 的 SSE 解析 + `sse_parser.dart` 随之下沉
2. **转换段上移 + 状态外置**
   - `BaseContextPolicy` 的装配算法 → `core/llm/context_assembly.dart`（无状态版：`(eligible, state, 参数) → (kept, card, newState)`）
   - **状态外置（design §10.1 #4 已拍 A）**：`_summary` / `_retained` / `_consumed` 三字段移出基建；业务持状态实例，类型定义在基建。状态取 **A 形态** `{摘要, 覆盖游标 k, 上次 eligible 长度}` —— 保留窗口 = `eligible[k..]`，**每轮由全量列表现算**，不再持有 `_retained` 列表；`_consumed` 的「上轮长度」并入 `k` 的变短/越界防御
   - `LocalContextPolicy` / `CloudContextPolicy` 变成基建内的**后端策略**（度量 + 预算 + 摘要实现），构造参数由服务解析配置后注入
3. **`converse` 落地**：`Llm.converse(List<ChatMessage> history, {ConverseSpec? spec}) → Stream<String>`，内部串联四段
4. **`prompt/conversation_strategy.dart` 拆分**：`buildSystemPrompt` 留 feature；`buildSummaryPrompt` 进基建（默认实现 + **App 级单一**覆盖点，**不按 feature 各写**）
5. **`ChatProvider` 瘦身**：持消息列表 + 持状态实例 + `llm.converse(...)`；删 `_resolvedMode` / `_defaultClientFactory` / 客户端构造
6. **取回段**：`eventsToText`（已在 Task 1）+ SSE delta 抽取 + think 剥离统一到入口施加（**云端是否剥 think 见 design §10.1 #5**）
7. **`ConversationStrategy` 三分**：`buildSystemPrompt` 留 feature；`buildSummaryPrompt` 进基建；**`isDuplicate`（有状态）**按 design §10.1 **#7** 落位——若留 feature 会造成 `core/llm/delivery` → feature 反向依赖
8. **`ChatClient.initialize({existingGoals})` 退场**：goals 改由业务读（`ChatProvider` 的 `getActiveGoals()`）并随 `spec` 每轮传人设；`_modelError` / `retryLoadModel()` / `_generateMockResponse()`（mock 兜底）归属按 design §10.1 **#8** 落定——**mock 兜底属业务，不随服务下沉**

**验证**
- [ ] `grep -rn "LlamaEngine" lib/features` **为空**；`grep -rln "Dio" lib/features` **只命中 `model_manager/`**（不变量 2 全量；模型下载的 Dio 不属 LLM 后端，见 design §8 复核记录 R3）
- [ ] `grep -rn "ChatMode" lib/features` 为空；`grep -rn "chatCloudMode" lib/features` 只命中 `features/settings/`（不变量 1）
- [ ] `grep -rn "ContextPolicy\|ConversationSummarizer" lib/features` **为空**（不变量 8：压缩无业务参数）
- [ ] `features/chat/engine/` 已解体：`client/`→交付、`context/`→转换、`prompt/`→人设留业务
- [ ] 业务文件不出现「本地/云端」分支
- [ ] `ChatProvider` 不再构造 client、不再读模式
- [ ] 端侧无状态重放不变量（2026-09-11 的四条）在交付层**仍然成立**（用例迁移后仍断言）
- [ ] 双端行为零回归：本地压缩/自愈/think 剥离、云端 SSE/取消/超时
- [ ] 测试迁移：`local_chat_client_test.dart` / `cloud_chat_client_test.dart` / 三个策略测试 全部落到新位置且绿
- [ ] `flutter analyze` 0；全量 `flutter test` 绿

**⚠️ 风险**：状态外置是**实打实的改造**（非 `git mv`）；A 形态（只存下标 `k`）必须带两条防御——① `eligible.length` 比上次**变短** → `reset()`；② 游标越界 → `reset()`。等价性以现有策略测试验证；若出现不等价先例，退回 B（状态持完整保留窗口列表）。

## Task 4：生命周期收口 ⬜ 未开始

> 依赖 Task 2（服务已存在）。落 design §9.4 / §10.1 #1。

**文件**

1. `ChatProvider` 移交 `loadModel()`（`:109-130`）、`dispose()` 里的 `_client?.dispose()`（`:94-97`）、`isModelLoading`（驱动整页 loading，`chat_page.dart:119`）。**注意 `loadModel()` 里混了互不相干的两件事**：① 后端就绪（随服务走）；② `getActiveGoals()` 注入人设（**属业务**，须留在 `ChatProvider`、改为随 `spec` 每轮传，见 design §10.1 #8）
2. 服务按模式驱动引擎：切本地 → 主动加载；切云端 → **延迟释放 + 防抖**；冷启动 → 异步加载不卡首帧；进会话未就绪 → 异步兜底
3. 模式通知源落地（design §10.1 #1 **已拍定**）：`SettingsRepository` 加**窄 `Listenable`**，只在 `setChatCloudMode` + `setCloudApiBaseUrl` / `setCloudApiKey` / `setCloudModelName` 后触发；服务订阅 → 「需要的后端（或三件套指纹）≠ 当前」→ 切换 / 重建，切换走延迟释放 + 防抖。**入口仍保留一次廉价复核当兜底**（不做二选一）
4. `chat_page.dart`：loading 改为消费服务的就绪状态

**验证**
- [ ] 切模式后行为符合预期（不反复加载/释放；冷启动首帧不阻塞）
- [ ] 未进对话页直接进 strategy_brief，本地模式下能自动就绪
- [ ] `ChatProvider` 不再持有加载/释放职责
- [ ] `flutter analyze` 0；全量 `flutter test` 绿

## Task 5：收尾 ⬜ 未开始

- [ ] 全量回归：`flutter analyze` 0 + 全量 `flutter test` 绿
- [ ] 文档：
  - `docs/PROJECT.md`：`五、架构`（分层与新模块）、`六、目录结构`（`core/llm` 扩写 + `features/chat/engine` 解体）、`十、设计决策`新增「大模型服务分层」行（三层/四段/三关节 + 不变量）
  - `docs/plans/2026-09-12-llm-service-layering-{design,plan}.md`：状态置完成
  - `.workbuddy/memory/MEMORY.md`：新增「大模型服务分层」条目（业务只调 `converse/ask`、后端差异关进 `core/llm`、类型在基建实例在业务）
- [ ] 冒烟项（**用户侧**，需真机/模拟器）：
  - 本地模式：多轮对话、压缩触发、`context full` 自愈
  - 云端模式：对话 SSE、**提取跟随配置**（关键：确认走云端且 JSON 解析成功）
  - 模式切换：本地→云端（延迟释放）、云端→本地（主动加载）、冷启动首帧不卡
  - 切换模式前后，摘要/提取无错配

## 依赖关系

```
Task 1 ──▶ Task 2 ──┬──▶ Task 3 ──┐
                    └──▶ Task 4 ──┴──▶ Task 5
```

Task 4 只依赖 Task 2（服务存在即可做），可与 Task 3 并行；Task 5 收尾。

## 关键实现备忘

- **不变量 1/2/6/8 都是 `grep` 可验的**：改造后应能用四条 grep 断言「业务层不知道后端、也不碰压缩内部」——这是骨架正确性的机器可查证据，比"看起来整齐"可靠。
- **`core` 不得依赖 feature**：`core/llm/*` 只可依赖 `core/*` 与 `models`（既有方向 `core 各域 → models/core`）。
- **压缩无业务参数**（design §5.1）：policy 的度量 / 预算 / 保底条数 / 溢出收缩 / 摘要模型**全部按后端解析**，业务侧零注入——不要为"将来可能需要"预留 per-feature 参数。
- **`buildSummaryPrompt` 上移**：它是**模型能力**差异（2B 需要更明确的指令/格式约束），不是业务差异；覆盖点放 **App 级配置**，**不进 `ConverseSpec`**。
- **`CloudSummarizer` 是半个现成的云端单次补全**：`:67-109`（Dio POST + `_extractContent`）抽出来后，云端 `ask` 近乎零成本。
- **交付是唯一形状差异**：云端「数据进请求」、端侧「数据进对象」；其余差异都是参数级。
- **状态外置前先验等价性（已拍 A）**：尾优先装箱的切点是**可推导**的（同列表 + 同预算 → 同一后缀），所以保留窗口不必被持有，只存下标 `k` 即可。既有测试断言「一次压缩后不再每轮触发压缩」——A 不改变这一点（`[0, k)` 已视作折进摘要、不再参与装箱 ⇒ 同样不会每轮调摘要器）；但**须先跑绿现有压缩/自愈用例再删 `_retained`**。
- **不做的事**：不钩子化；不改装配算法；不做 KV 复用；不做多后端降级链；不动服务端。
