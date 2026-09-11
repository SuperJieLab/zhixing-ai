# 知行AI — ContextPolicy 抽象实施计划

> 状态：已完成（Task 1–4 全部交付；Task 4 仅余「用户侧冒烟」待执行）
> 设计：`docs/plans/2026-09-11-context-policy-design.md`（能力对等 / 双端各一份策略 / 云端摘要用云端模型）
> 时机：**排在 BYOK 真机冒烟之后**（本重构覆盖两个 client 的装配路径，不与未验证变更混提）
> 纪律：每 Task 实现 → 自查 → 全量回归 → 改动留工作区，由用户确认后提交（不自动 commit）
> 测试命令（沙箱代理会拦截 flutter_tester，须一并清 ALL_PROXY）：
> `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u ALL_PROXY -u all_proxy NO_PROXY='*' no_proxy='*' flutter test`

## Task 1：抽取共享层骨架（零行为变更）✅ 已完成

**文件**
- 新增 `lib/features/chat/engine/context_policy.dart`：
  - `AssembledContext`（`messages` + `summaryCard`）、`PackResult`（`kept`/`evicted`/`used`）
  - `abstract class ContextPolicy { Future<AssembledContext> assemble(history, {systemPrompt}); Future<void> handleOverflow(); }`
  - `abstract class ContextEstimator { estimateMessage(ChatMessage); estimateText(String); estimateMessages(List) 默认累加 }`
  - `abstract class ConversationSummarizer { Future<String> summarize(previousSummary, evicted); }`
  - 共享纯函数：`filterEligible`（剔 round==0）、`packTailWithinBudget`（尾部优先 + `minKeep` 保底 + 返回 kept/evicted/used）、`packKeepLast`（溢出自愈硬收缩）
  - **`BaseContextPolicy`**（abstract，共享装配编排：过滤 → 装窗 → 摘要，含"已摘要游标"防重复摘要；差异全部由构造参数注入）——①③⑤「同一段代码」的落点
  - 不引用任何端侧概念（红线）
- 新增 `test/features/chat/engine/context_policy_test.dart`：20 用例

**验证**
- [x] 单测 20：过滤剔 round==0；装窗（长消息少留/短消息多留）；`minKeep` 保底；预算充足全量透传；evicted 前缀切分；baseCost 占预算；强制收缩（overflowKeep 非 null / null）；摘要游标不重复摘要；摘要失败回落；无摘要器；摘要截断
- [x] 不接任何 client，`flutter analyze` 0；全量 `flutter test` **153/153** 绿（新增 20，既有 133 无回归）

## Task 2：LocalChatClient 委托 LocalContextPolicy ✅ 已完成

**文件**
- 新增 `lib/features/chat/engine/local_context_policy.dart`：
  - `LocalContextPolicy extends BaseContextPolicy`：**只做配置装配**（`LlamaTemplateEstimator` / `localInputBudget` / 注入的摘要器 / minKeep=2 / overflowKeep=4）
  - `LlamaTemplateEstimator extends ContextEstimator`：`LlamaService.estimateTokens` + 每条 `+16` overhead（`perMessageOverhead`）
  - `LlamaSummarizer implements ConversationSummarizer`：`llamaSummarizer` 逻辑迁入（一次性独立 KV 会话 + think 剥离），入参由 `ChatMessage` 转 records
- 改 `lib/features/chat/engine/local_chat_client.dart`：
  - 删除内嵌的 `_compactContext` / `_summary` / `_estimatedTokens` / `_truncateThreshold` 与 `Summarizer` typedef / `llamaSummarizer`
  - 保留会话增量态：`_consumed`（diff 游标）、`_skipNextHistoryAi`
  - `generateResponse`：`policy.assemble(history, systemPrompt:)` → `evicted` 则按 `AssembledContext` 重建 KV 会话（persona → 摘要卡 → kept），否则从游标增量 append
  - context full 自愈：捕获 → `policy.handleOverflow()` → 立即重新装配并重建（下一轮直接可用）
  - 构造缝：`ContextPolicy? policy` + `ConversationSummarizer? summarizer`
- 改 `test/features/chat/engine/local_chat_client_test.dart`：摘要器 fake 改为 `ConversationSummarizer`；`truncateThreshold: 0` 改为 `policy: LocalContextPolicy(budget: 0, …)`
- 新增 `test/features/chat/engine/local_context_policy_test.dart`：度量单位 + 参数装配（6 用例）

**⚠️ 计划内的行为变更（由共享过滤带来）**
- 端侧不再把**第 0 轮欢迎语**当对话上下文送进 KV 会话（此前 diff 全量 → 现在与云端统一走 `filterEligible`）。省 ~百 token 预算且消除双端不一致。
- 因此 `welcome` 相关断言与「压缩移出条数」（18 → 17）已按新语义更新；`消息数 ≤ 保底` 的旧用例语义变为「不触发压缩、不重建」。

**验证**
- [x] 单测：assembled 驱动 KV 会话重建（persona → 摘要卡 → kept 顺序）；溢出 → 当轮降级文案 + 策略收到 `handleOverflow` + 立即重建
- [x] 既有本地语义零回归（diff/去重/think/取消跳过/失败跳过/恢复会话 seed）
- [x] `flutter analyze` 0；全量 `flutter test` **162/162** 绿

## Task 3：CloudContextPolicy + CloudSummarizer ✅ 已完成

**文件**
- 新增 `lib/features/chat/engine/cloud_context_policy.dart`：
  - `CloudContextPolicy extends BaseContextPolicy`：**只做配置装配**——`CharCountEstimator`（字符数近似 + 每条 16 包装开销）+ `AppConstants.cloudInputBudget`（60000 字符，见 design §5 预算结论）+ `CloudSummarizer` + `minKeep = 2` + `overflowKeep: null`
  - 溢出为无收缩（`overflowKeep: null`，由基类承接），云端预算充裕、契约保持一致
- 新增 `lib/features/chat/engine/cloud_summarizer.dart`：`CloudSummarizer implements ConversationSummarizer`，复用同一 BYOK 端点，`stream: false`、`max_tokens: 512`、prompt 用 `ConversationStrategy.buildSummaryPrompt`、结果过 `stripThinkTags`；非 2xx / 畸形响应抛错由策略兜底
- 改 `lib/features/chat/engine/cloud_chat_client.dart`：
  - 删除 `_windowSize = 10` 硬编码与内联过滤，改为 `_policy.assemble(history, systemPrompt:)`
  - 新增 `ContextPolicy? policy` 注入缝（默认按 BYOK 三件套装配 `CloudContextPolicy`）；`initialize` 调 `_policy.reset()`
  - `generateResponse` 拆为「同步空校验 + `_assembleAndGenerate`（async* 装配后 yield* 传输流）」，保留空历史的同步 `ArgumentError` 语义
  - 请求体装配：`system(persona)` → 摘要卡（如有，同为 system 消息）→ payload
- 新增 `test/.../cloud_context_policy_test.dart`（6 用例）、`cloud_summarizer_test.dart`（6 用例）；`cloud_chat_client_test.dart` 的 E 用例改为「预算内全量携带」并新增 K「小预算装窗」

**验证**
- [x] `CloudContextPolicy`：度量（字符数 + overhead）、预算内透传、共享过滤（round==0）、小预算压缩（留 minKeep + 摘要器收到移出消息）、`handleOverflow` 无害、`reset` 清空摘要/窗口
- [x] `CloudSummarizer`：请求体断言（非流式 / model / max_tokens / Bearer / 摘要提示词）、递归压实（旧摘要并入）、think 剥离、401 抛错、缺 choices / 缺 content 抛错
- [x] `CloudChatClient` 既有用例（A–J）+ 新增 K 全绿；D 语义不变（round==0 过滤后全量携带）
- [x] `flutter analyze` 0；全量 `flutter test` **175/175** 绿（Task 2 基线 162 + 新 12 + client 新 1）

## Task 4：收尾

- [x] 全量回归：`flutter analyze` 0 + 全量 `flutter test` **175/175** 绿 + `server npm test` **4/4** 绿（未波及：服务端不参与对话链路）
- [x] 文档：
  - `docs/PROJECT.md`：engine 目录树补 `cloud_context_policy.dart` / `cloud_summarizer.dart`，`cloud_chat_client.dart` 说明改为「装配交策略」；架构图 Engine 层补 `ContextPolicy`；设计决策表补「上下文管理」「云端摘要」两行并更新「传输层」行
  - `README.md`：`constants.dart` 说明补云端输入预算（云端对话/BYOK 描述原本已准确，无需改）
  - `docs/plans/2026-09-11-context-policy-design.md` §5 回填预算结论（原「待定」）
- [x] 更新 `.workbuddy/memory/MEMORY.md`：ContextPolicy 落地记录（能力拆解、双端策略参数、红线、测试命令）
- [ ] 冒烟项（**用户侧**，需真机/模拟器执行）：
  - 本地长对话触发压缩（摘要卡生效、触发轮延迟可接受）
  - 云端配置后正常对话（预算内历史全量携带、无异常）
  - 云端人为构造超长对话验证压缩路径可走通（并确认 `cloudInputBudget` 对所选模型是否合适）
- [ ] 范围外备忘：异步预压缩、摘要持久化仍为后续候选

## 依赖关系

```
Task 1 ──▶ Task 2 ──┬──▶ Task 4
         └▶ Task 3 ──┘
```

Task 1 独立可交付（纯新增，零行为变更）；Task 2、3 互不依赖（各自 client），可顺序执行或并行；Task 4 收尾统一回归。

## 关键实现备忘

- **保底最后 2 条**的原因（沿用 2026-09-09 决策）：当前用户消息已 append 进旧 KV 会话，不能只存在于摘要卡里，否则模型看不到本轮问题原文。
- **摘要卡不伪装成 ChatMessage**：`ChatMessage` 无 system 角色，扩展模型会污染数据层；改为 `AssembledContext.summaryCard` 由 client 注入。
- **`handleOverflow` 是中性钩子**：本地 client 捕获 `LlamaDecodeException` 后调用；cloud 侧保留空实现以维持契约对称。
- **防泄漏红线**：共享层不得出现 `nCtx`/`llama`/`EngineChat`；端侧细节全部封装在 `LocalContextPolicy` 及其实现内。
- **待定参数**：云端预算单位与数值（建议字符数近似，量级 10 万字符）；实现时在 design 文档回填结论。
- **既有语义不可动**：diff 增量 append、`_skipNextHistoryAi`、尾部用户消息去重改写、think 剥离——均非本抽象职责。
