# 知行AI — ModelGateway 门面重构实施计划

> 状态：**⬜ 未开工**（Task 1–7 待实施）
> 设计：`docs/plans/2026-09-14-model-gateway-facade-design.md`（D1–D7 决策已拍定，可开工）
> 前置：v1 分层已完成（`2026-09-12-llm-service-layering-{design,plan}.md`，基线 `main`）；本次**不推翻底座**——Policy / Generation（原 Delivery）/ 自愈逻辑平移复用，动的是门面方向、状态归属与目录。
> 提交纪律：每 Task 实现 → 自查 → 全量回归 → 改动留工作区，由用户确认后提交（**不自动 commit**）
> 推进原则：**strangler 式增量**——每 Task 结束 `flutter analyze` 0 + 全量测试绿；新路径先并存 → 再切消费方 → 最后删旧路径。
> 测试命令（宿主代理会拦截 flutter_tester，须一并清 ALL_PROXY）：
> `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u ALL_PROXY -u all_proxy NO_PROXY='*' no_proxy='*' flutter test`
> 基线：`flutter analyze` 0；全量测试绿（以开工当日实际数字为准，v1 收尾时为 177+）

## Task 1：ask 输入预算守门（独立可交付，业务无感）✅ 已完成（2026-09-14）

> **实施记录**：analyze 0 + 全量 218 绿（基线 + 8 新增用例）。两处与计划的偏差——① 守门施加点取 `ask()` 方法体（`_resolveCompleter` 之后）而非 `_resolveCompleter` 内部：`askJson` 经 `ask` 透传自动覆盖，且其 JSON-only directive 随本次度量一并计入（固定 30 字符，注释已说明口径）；② 度量含 `2 × 每条消息包装开销`（`LlamaTemplateEstimator`/`CharCountEstimator` 各自常量），与 converse 逐条累加口径对齐、宁保守勿漏放；开销取值用轻量 `is` 分派（无反射）。边界用例实测修正：云端边界内输入须为 `budget − 2×16 − system长度`（初版用例漏算 system 占用，被测试抓住）。

**目标**：修 design §一.3 的现网缺口——`ask` / `askJson` 完全绕过预算，本地超 nCtx 无承接、云端超长输入无信号。落点在 **llm 基建补全唯一通道**（D5），业务零改动、网关透传自动获得。

**文件**

1. 新增 `lib/core/llm/input_guard.dart`
   - `void ensureInputWithinBudget({required ChatMode mode, required String system, required String user})`：按模式选度量器——本地 `LlamaTemplateEstimator`（`context_budget.dart:35`，与 `converse` 同 nCtx 口径）、云端 `CharCountEstimator` 对 `cloudInputBudget`（`cloud_context_policy.dart:10` / 预算常量）度量 `system + user`；
   - 超预算抛 `GatewayInputOverflowException`（类型化，message 带模式与实际/上限数值）；
   - 红线：纯函数、无状态；**不截断、不自愈**（D5：截断 = 提取「成功但错误」无信号；单次调用无可牺牲历史）。
2. 改 `lib/core/llm/llm_service.dart`
   - `_resolveCompleter` 返回前（即 `ask` / `askJson` 共同入口）施加守门——单点施加，两条路径都覆盖；
   - `askJson` 守门须计入 `_jsonOnlyDirective` 追加后的最终 system 文本（在 `ask` 内部追加之前度量原始输入即可， directive 固定且极短——取「度量原始输入」口径，注释说明）。
3. 新增 `test/core/llm/input_guard_test.dart`
   - 本地：超 `localInputBudget`（1668 token 口径）抛异常；边界内不抛；`maxTokens` 与守门无关（守门只量输入）；
   - 云端：超 `cloudInputBudget`（60000 字符）抛异常；边界内不抛；
   - 经 `LlmService.ask` / `askJson` 端到端：超预算抛 `GatewayInputOverflowException`、请求函数不被触达（fake `SingleShotAsk` 计数 0）。

**验证**
- [x] `grep -n "ensureInputWithinBudget" lib/core/llm/llm_service.dart` 命中 `ask` 路径（askJson 经 ask 共享）
- [x] 守门失败时 fake 补全函数零调用（fail-fast，不发生网络/引擎动作）
- [x] `flutter analyze` 0；全量测试绿（基线 + 新增）

## Task 2：LlmService 暴露模式源（T3 的前置）✅ 已完成（2026-09-14）

> **实施记录**：analyze 0 + 全量 220 绿（+2 用例）。**实施中拍定 notifier 写入语义**：计划原稿的「单写」不可行——旧测试不经 `initialize()` 不注册监听，纯通知驱动的 notifier 会丢 v1「每次现读设置」的入口复核语义（单测当场抓住）。落为**双写点、同值不通知**：① `_mode` getter 现读设置时顺手同步（保底纠偏）；② `_onBackendSettingChanged` 收通知时提前同步（让 D3 的监听者不必等下一次模式解析才看到变更）。`_mode` 之外的解析语义为零，单一解析点不变。

**目标**：给网关提供可注入的 `ValueListenable<ChatMode>`，保持唯一模式解析点仍在 `LlmService._mode`（D2）。

**文件**

1. 改 `lib/core/llm/llm_service.dart`
   - 新增 `final ValueNotifier<ChatMode> _modeNotifier`；`_mode` getter 改读 notifier（或保留现读设置 + notifier 同步双轨，**取 notifier 单写**：`_onBackendSettingChanged` 与构造/`initialize` 时写入，`_mode` = `_modeNotifier.value`——入口复核语义由「每次写 notifier 前现读设置」保持）；
   - 暴露 `ValueListenable<ChatMode> get mode`。
2. 改 `test/core/llm/llm_service_test.dart`
   - 新增：构造后 notifier 值与设置一致；`backendListenable` 触发切换后 notifier 同步更新（本地→云端→本地往返）。

**验证**
- [x] 模式切换 → `service.mode.value` 即时正确（含 BYOK 三件套变更不误触发模式值变化）
- [x] 既有 llm_service 用例全绿（行为不变）

## Task 3：ModelGateway 对话面（编排平移，双轨并存）✅ 已完成（2026-09-14）

> **实施记录**：analyze 0 + 全量 229 绿（+9 网关用例）。两处实施拍定——① **D3 的 reset 落为 `ContextState.resetWindow()` 新方法**：既有 `reset()` 连摘要一起清，与 D3「保摘要、清游标」矛盾，故在 `context_assembly.dart` 增窗口级重置（k / lastEligibleLength / pendingForceKeep 清零、summary 不动）；② **交付接缝形态**：网关不缓存工厂结果（每轮经工厂取实例，稳定实例语义归工厂——生产侧 `LlmService.deliveryFor`（本 Task 由 `_deliveryFor` 转公开）自持池化 + BYOK 指纹重建，测试侧返回自持稳定 fake）；网关生产缺省工厂缺省时报语义错误（composition root 未注入即显式失败）。摘要统一走 `llm.ask`（D4）已随策略构造落地；`await for` 红线保持。`LlmService.converse` 双轨保留，业务未切。

**目标**：新建门面，持 `ContextState`、编排装配 → 生成 → 自愈（逻辑自 `LlmService.converse` **逐字平移**，D2–D4）。`LlmService.converse` 暂留，业务未切。

**文件**

1. 新增 `lib/core/model_gateway.dart`
   - 构造：`ModelGateway({required Llm llm, required ValueListenable<ChatMode> modeSource})`（D1：core 根单文件）；
   - **状态归属迁移**：私有 `final ContextState _state = ContextState()`（自 ChatProvider 收回，design §二）；
   - `converse(history, {required String systemPrompt}) → Stream<String>`：按 `modeSource.value` 现选策略（`LocalContextPolicy` / `CloudContextPolicy` 无状态实例）→ `assemble` → 生成（Task 3 阶段先委托 `llm` 侧既有交付路径，或直接注入 `ChatDelivery` 工厂接缝——**落法见本 Task「已拍定」**）→ `await for` 转发（**红线：禁止 `yield*`**，v1 教训）→ `LlmContextOverflowException` 承接自愈（`handleOverflow` → 重新装配 → `prime(nudgeTail:false)` → `kLlmFailureReply`）；
   - **模式切换防御（D3）**：监听 `modeSource`，变更时 `_state.reset()`（保摘要、清游标记账）；
   - **摘要器统一（D4）**：策略构造时注入 `SingleShotSummarizer(llm.ask)`——策略对象不再持摘要器差异；
   - 补全面透传（一行委托）：`ask` / `askJson` / `stop` / `isReady` / `readiness`；
   - re-export：`export 'core/llm/llm.dart' show ChatMode, LlmReadiness;`（业务类型可见、实现不可见）。
2. **已拍定（网关与交付的接缝形态）**：网关**不**经 `llm.converse`（T5 要删它），而是注入**交付工厂接缝** `ChatDelivery Function()? deliveryFactory`（自 `LlmService._deliveryFor` 平移：本地 `LocalDeliveryBuilder` + 云端 BYOK 指纹重建逻辑一并移入网关；`LlmService.converse` 双轨期继续走自己的旧路径）。
3. 测试：新增 `test/core/model_gateway_test.dart`——自 `llm_service_test.dart` 平移编排类用例（装配 → 生成 → 自愈、构建中切云端弃置、模式切换 reset 摘要保留）+ 新增网关专属用例（策略按 modeSource 现选、`ask/askJson` 守门经透传生效）。

**验证**
- [x] 编排逻辑与 `LlmService.converse` 无语义差异（逐字平移 + `await for` 红线保持）
- [x] 模式切换后首轮：`state.k` 已 reset、摘要文本保留
- [x] 网关 `ask` 超预算抛异常（守门经 llm 透传自动生效）
- [x] 业务零改动（`ChatProvider` / `strategy_brief` 仍走旧路径）
- [x] `flutter analyze` 0；全量测试绿

## Task 4：业务切换（消费方迁到门面）✅ 已完成（2026-09-14）

> **实施记录**：analyze 0 + 全量 229 绿。两处偏差——① 网关补 `ensureReady()` 透传（design §四漏列）：`chat_page` 的失败重试 / 兜底加载依赖它，一行委托与 readiness 同性质；② re-export 增补 `LlmPhase`（页面 switch 就绪态用）。`main.dart` 双 Provider 并存（`ModelGateway` 上线、`Llm` 保留至 T5 删）。`FakeGateway` 落 `test/support/fake_llm.dart`（内部持 `FakeLlm` 全委托），chat_provider_test 断言不改语义、仅「状态跨轮同实例」用例改写为「状态已收回门面」（该不变量已由 model_gateway_test 覆盖）。红线核过：`lib/features` 无 `Llm` 接口引用、无 `ContextState` 使用（仅 doc 注释）。

**目标**：两个消费方切到 `ModelGateway`，旧路径进入只读保留期。

**文件**

1. 改 `lib/features/chat/providers/chat_provider.dart`
   - 依赖改 `ModelGateway`（构造注入）；删 `_contextState`（`:35`）与 `converse` 的 `state:` 实参（`:149-153`）；
   - `isReady` / mock 兜底逻辑不变（`_generateMockResponse` 留业务）。
2. 改 `lib/features/chat/chat_page.dart`——`context.read<Llm>()`（`:44` / `:123`）改读 `ModelGateway`；readiness 消费类型不变（re-export 保证）。
3. 改 `lib/features/strategy_brief/`——`strategist_extractor.dart:112` 的 `_llm.askJson`、`strategy_brief_provider.dart:56,67`、`strategy_brief_page.dart:26` 全部改 `ModelGateway`。
4. 改 `test/`——`chat_provider_test.dart`、`chat_page_test.dart` 等改注入 `FakeGateway`；`test/support/fake_llm.dart` 增补 `FakeGateway`（实现网关公开面，内部持 `FakeLlm`）。

**验证**
- [x] `grep -rn "\bLlm\b" lib/features` **为空**（业务不再 import 基建接口）
- [x] `grep -rn "ContextState" lib/features` **为空**（状态收回完成）
- [x] 对话 / 提取行为与 Task 3 前一致（全量测试绿，业务用例不改断言）

## Task 5：收口（删旧路径 + composition root）✅ 已完成（2026-09-14）

**实施记录**（与原计划的偏差已标注）：

1. 删 `Llm.converse`（接口 + `ChatMessage`/`context_assembly` import）与 `LlmService.converse`；`_policyFor` / `_policyFactory` 接缝一并删除（仅 converse 使用）。**保留** `deliveryFor`（公开，生产交付工厂经 main 注入网关）与 `_deliveryFactory` / `_overrideDelivery` / `_localDeliveryBuilder`（生命周期测试仍依赖）——原计划第 2 点「若网关已自持则一并移除」判定为不移除：交付稳定实例语义归工厂（T3 拍定）。
2. 删 `llm_service_test` 的 converse 编排组（6 用例，已平移网关测试）+ `_FakePolicy` / `_FakeDelivery`；`FakeLlm` 删 `converse` override（`Llm` 已无此方法），脚本化字段（`onConverse` / `converseCalls`）保留、由 `FakeGateway.converse` 写入——业务测试 API 零改动。
3. `main.dart` 在 T4 已完成注入收口（仅 `Provider<ModelGateway>`），本任务无改动。

**验证**
- [x] `grep -rn "converse" lib/core/llm` 零残留（编排只存在于 `core/model_gateway.dart`）
- [x] `LlmService` 职责收敛为：模式解析 + ask/askJson/readiness/生命周期/交付工厂
- [x] `flutter analyze` 0；全量 223 绿（删 6 旧用例后基线 229→223）

## Task 6：文档与记忆同步

1. `docs/PROJECT.md` 大模型服务分层章节：补 v2 门面结构（gateway / context / generation / single_shot 星形依赖图、ContextState 归属变更、守门契约）；
2. `.workbuddy/memory/MEMORY.md`：更新「大模型服务分层」节——`Llm` 降为基建接缝、业务唯一入口 `ModelGateway`、目录新约定；标注 v1 描述过时项。

## Task 7：目录重组（D7 终版，纯移动 + 注入改造）✅ 已完成（2026-09-14）

**实施记录**（与原计划的偏差已标注）：

1. **7a context 域**：`core/context/` = `context_state.dart`（自 context_assembly 拆出）/ `context_assembly.dart` / `context_budget.dart`（LlamaTemplateEstimator 移出）/ `local_context_policy.dart`（**estimator 改必注入**）/ `cloud_context_policy.dart`（CharCountEstimator 纯字符、留域内）/ `summary_prompt.dart`。摘要传输实现 `SingleShotSummarizer` 同时依赖两域类型 → **内聚为门面文件里的公开 `AskSummarizer`**（`core/model_gateway.dart`，公开仅为可测）；`SingleShotAsk` typedef 迁入 `llm.dart`（`llm_service.dart` 保留 re-export）。
2. **7b 分桶 + 改名**：`generation/`（generation.dart / local_generation.dart / cloud_generation.dart / sse_parser / tail_dedup / think_stream_filter）、`single_shot/`（input_guard / think_tag_stripper / cloud_request.dart←cloud_completion、local_inference.dart←inference）、`engine/`（llama_service / active_model_manager / llama_template_estimator←context_budget）。类名：`ChatDelivery→ChatGeneration`、`LocalDelivery→LocalGeneration`（typedef 随名 `LocalGenerationBuilder`）、`CloudDelivery→CloudGeneration`、`CloudCompletion→CloudCompletionRequest`。test 同构镜像（context 测试 → `test/core/context/`）。
3. **input_guard 重写为 llm 域自足**：不再 import context（原经 `ContextEstimator` 抽象），度量按模式内联（本地 token + 2×16 / 云端字符 + 2×16），口径不变——这是「llm 不 import context」在守门处的落法。

**与计划的偏差（两处，均已核）**：

- **红线口径修正**：原验证项「`lib/core/llm` 不 import `context`」**过严，不可达成**——generation 段消费 `AssembledContext` / `kLlmFailureReply` 等装配契约类型是本质依赖。以设计文档 D7 的原始表述为准：**禁 `context → llm`（已达成，grep 零命中）与业务直连两域**；`llm → context` 单向允许（契约类型），策略规则仍不进 llm。
- **已知例外**：`strategist_extractor` 直连 `core/context/context_budget.dart`（装箱原语）与 `core/llm/engine/llama_template_estimator.dart`——其自有输入截断语义（minKeep:0 主动收缩）先于守门存在，T7 不扩 scope 改语义。**建议后续**：把该截断下沉门面（如 `ModelGateway.truncateForAsk`）或让守门提供收缩变体，届时业务 import 可归一。

**验证**
- [x] 目录树与 design D7 终版逐项一致
- [x] 依赖红线：`context → llm` 零命中；业务零直连（除上述已登记例外）；门面是唯一组合点
- [x] **零行为变更**（全量测试绿，无断言修改——改名导致的引用修正除外）
- [x] `flutter analyze` 0；全量 223 绿

## 风险与回退

| 风险 | 缓解 |
|---|---|
| 编排平移引入语义漂移（自愈/去重/双轨不一致） | Task 3 逐字平移 + 用例平移对照；红线 `await for` |
| 模式切换 reset 时机（监听回调 vs 首轮现查） | Task 3 用例锁定：切换后首轮 `k` 已清、摘要保留 |
| 双轨期两套编排并存的行为分叉 | 双轨仅 Task 3–4 存在，Task 5 即删；期间业务只走旧路径 |
| T7 大移动 + 改名波及面大 | 拆 7a/7b 两个 commit；先移动后改名分步跑 analyze |
| 端侧守门口径与 converse 不一致 | 同一 estimator、同一 nCtx 口径（Task 1 用例锁定） |
