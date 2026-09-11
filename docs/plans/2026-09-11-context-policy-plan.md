# 知行AI — ContextPolicy 抽象实施计划

> 状态：进行中（Task 1 已完成/待提交，Task 2/3/4 待执行）
> 设计：`docs/plans/2026-09-11-context-policy-design.md`（能力对等 / 双端各一份策略 / 云端摘要用云端模型）
> 时机：**排在 BYOK 真机冒烟之后**（本重构覆盖两个 client 的装配路径，不与未验证变更混提）
> 纪律：每 Task 实现 → 自查 → 全量回归 → 改动留工作区，由用户确认后提交（不自动 commit）
> 测试命令（沙箱代理会拦截 flutter_tester）：
> `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy NO_PROXY='*' no_proxy='*' flutter test`

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

## Task 2：LocalChatClient 委托 LocalContextPolicy

**文件**
- 新增 `lib/features/chat/engine/local_context_policy.dart`：
  - `LocalContextPolicy extends BaseContextPolicy`：**只做配置装配**（estimator / budget / summarizer / minKeep=2 / overflowKeep=4），编排逻辑由共享骨架承接，不再迁移状态机
  - `LlamaTemplateEstimator extends ContextEstimator`：`LlamaService.estimateTokens` + 每条 `+16` overhead（沿用现有常数）
  - `LlamaSummarizer implements ConversationSummarizer`：包一层现有 `llamaSummarizer`
- 改 `lib/features/chat/engine/local_chat_client.dart`：
  - 客户端**保留**会话增量态（`_mirror` / `_consumed` / `_skipNextHistoryAi`，属 diff 语义非本抽象职责）；**移除** `_compactContext` / `_summary` / `_estimatedTokens` / `_truncateThreshold`（迁入 policy/骨架）
  - `generateResponse`：先 `policy.assemble(history)`，按 `AssembledContext` 重建/补齐 session（`addSystem(persona)` → 摘要卡 → append kept）；捕获 `LlamaDecodeException` → `policy.handleOverflow()` → 本轮降级文案、下轮恢复
  - 构造缝：`ContextPolicy? policy`（测试注入 fake policy）；`engine` 存在时默认构造 `LocalContextPolicy`
- 改 `test/features/chat/engine/local_chat_client_test.dart`：原 compact 相关用例迁移/改造为 policy 注入路径；client 保留断言 diff 增量、`_skipNextHistoryAi`、去重改写、think 剥离、溢出降级

**验证**
- [ ] 单测：assembled 结果驱动 session 重建（persona → 摘要卡 → kept 顺序）；溢出 → 当轮降级文案 + policy 收到 `handleOverflow`
- [ ] 既有本地语义零回归（diff/去重/think/恢复会话全量 seed）
- [ ] `flutter analyze` 0；全量 `flutter test` 绿

## Task 3：CloudContextPolicy + CloudSummarizer

**文件**
- 新增 `lib/features/chat/engine/cloud_context_policy.dart`：
  - `CloudContextPolicy extends BaseContextPolicy`：**只做配置装配**——`HeuristicEstimator`（字符数近似）+ 大预算（待定数值，见下）+ `CloudSummarizer` + `minKeep = 2` + `overflowKeep: null`
  - 溢出为无收缩（`overflowKeep: null`，由基类承接），云端预算充裕、契约保持一致
- 新增 `lib/features/chat/engine/cloud_summarizer.dart`：`CloudSummarizer implements ConversationSummarizer`，复用同一 BYOK 端点，`stream: false`、`max_tokens: 512`、prompt 用 `ConversationStrategy.buildSummaryPrompt`、结果过 `stripThinkTags`；非 2xx 抛错由策略兜底
- 改 `lib/features/chat/engine/cloud_chat_client.dart`：
  - 删除 `_windowSize = 10` 硬编码与内联过滤，改为 `policy.assemble(history)`
  - 请求体装配：`system(persona)` → 摘要卡（如有）→ payload
- 新增/改测试：`cloud_context_policy_test.dart`、`cloud_summarizer_test.dart`；`cloud_chat_client_test.dart` 窗口相关用例按新语义更新

**验证**
- [ ] 单测：预算内透传（历史全量携带）；构造小预算强制触发压缩路径；`handleOverflow` 不破坏后续装配
- [ ] `CloudSummarizer`：请求体断言（非流式、model、max_tokens、Bearer）、响应解析、think 剥离、非 2xx 抛错
- [ ] `CloudChatClient` 既有用例（A–J：系统提示词/窗口/Bearer/401/无 content 帧等）全绿
- [ ] `flutter analyze` 0；全量 `flutter test` 绿

## Task 4：收尾

- [ ] 全量回归：`flutter analyze` 0 + 全量 `flutter test` 绿 + `server npm test`（应无波及）
- [ ] 文档：`docs/PROJECT.md` 架构图/决策表补充 ContextPolicy 层；README 若涉云端对话描述同步
- [ ] 更新 `.workbuddy/memory/MEMORY.md`：ContextPolicy 落地记录（能力拆解、双端策略参数、红线）
- [ ] 冒烟项（用户侧）：本地长对话触发压缩（摘要卡生效、触发轮延迟）；云端配置后正常对话（窗口内历史携带、无异常）；云端人为构造超长对话验证压缩路径可走通
- [ ] 范围外备忘：异步预压缩、摘要持久化仍为后续候选

## 依赖关系

```
Task 1 ──▶ Task 2 ──┬──▶ Task 4
         └▶ Task 3 ──┘
```

Task 1 独立可交付（纯新增，零行为变更）；Task 2、3 互不依赖（各自 client），可顺序执行或并行；Task 4 收尾统一回归。

## 关键实现备忘

- **保底最后 2 条**的原因（沿用 2026-09-09 决策）：当前用户消息已 append 进旧 session，不能只存在于摘要卡里，否则模型看不到本轮问题原文。
- **摘要卡不伪装成 ChatMessage**：`ChatMessage` 无 system 角色，扩展模型会污染数据层；改为 `AssembledContext.summaryCard` 由 client 注入。
- **`handleOverflow` 是中性钩子**：本地 client 捕获 `LlamaDecodeException` 后调用；cloud 侧保留空实现以维持契约对称。
- **防泄漏红线**：共享层不得出现 `nCtx`/`llama`/`EngineChat`；端侧细节全部封装在 `LocalContextPolicy` 及其实现内。
- **待定参数**：云端预算单位与数值（建议字符数近似，量级 10 万字符）；实现时在 design 文档回填结论。
- **既有语义不可动**：diff 增量 append、`_skipNextHistoryAi`、尾部用户消息去重改写、think 剥离——均非本抽象职责。
