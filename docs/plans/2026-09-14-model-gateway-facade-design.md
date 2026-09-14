# 设计文档：ModelGateway 门面重构（大模型服务分层 v2）

日期：2026-09-14
状态：待评审
前置：`docs/plans/2026-09-12-llm-service-layering-{design,plan}.md`（v1 分层，本次在其基础上调整门面方向，不推翻底座）

## 一、问题陈述

v1 分层把后端差异关进了 `core/llm`，但门面开错了方向：

1. **业务面朝大模型服务**，而非上下文管理。`ChatProvider` 调 `Llm.converse(history, systemPrompt, state)`，要喂 3 个上下文相关参数，且自己持有 `ContextState` 实例——摘要卡、挤出游标这些是业务不该关心的细节。
2. **编排逻辑在 LlmService**。装配 → 交付 → 溢出自愈这条链写在 `converse` 里，而按职责它属于上下文层。
3. **单次补全链路裸奔**。`ask` / `askJson` 完全绕过 `ContextPolicy`，无任何输入预算守门：本地端超 nCtx 无承接，云端超长输入无信号。
4. **业务依赖面有两个入口**。Chat 走 `converse`，strategy_brief 走 `askJson`，都直接 import `Llm`。

目标形态（与用户对齐的结论）：

> **ModelGateway = 业务唯一门面**：对话面有状态（装配 + 压缩 + 自愈），补全面无状态透传（含输入预算守门）。`Llm` 降级为基建内部接缝，业务永久不 import。

## 二、目标分层

```
ChatProvider ──────┐
                   ├──► ModelGateway（core/ 根，业务唯一门面 = 唯一组合点）
strategy_brief ────┘         │
                对话面（有状态）│         补全面（无状态透传 + 守门）
                converse(history, systemPrompt)   ask / askJson / stop / readiness
                持 ContextState；编排：            守门实现在 llm 基建（见 D5）
                装配 → 生成 → 溢出自愈
                     ┌──────┴──────┐
                     ▼             ▼
        core/context/          core/llm/
        ContextState           Llm（ask/askJson/readiness/stop）
        ContextAssembly        generation/（ChatGeneration，Local/Cloud）
        Local/Cloud 策略参数    single_shot/（BYOK 请求 / 端侧推理 / 守门）
        （参数档案，注入式）     engine/（LlamaService 池）
                     │             │
                     └──────┬──────┘
                            ▼
                llama.cpp / BYOK 端点（后端原语）
```

依赖规则变化（星形，单向禁环）：

- **业务（pages / widgets / providers / feature engine）只准 import `ModelGateway`**，禁止 import `Llm` / `LlmService` / context 域类型（`LlmReadiness` / `ChatMode` 经 model_gateway.dart re-export）；
- `context` 与 `llm` **互不依赖**，唯一组合点是 `ModelGateway`；
- `ContextState` 从业务收回：**实例在网关私有**（v1 是实例在业务）；
- `ChatProvider` 三件事变为两件事：持 `_messages`（唯一真值源）+ 每轮传人设；不再持 `ContextState`。

## 三、设计决策

### D1 命名：`ModelGateway`

双面职责（上下文管理 + 补全门面）下「ContextManager」名不副实；「Manager」是空词。定为 `ModelGateway`，位于 `core/model_gateway.dart`（core 根单文件组合层，见 D7 的星形依赖）。

### D2 模式感知：注入模式源，不自读设置

- `ModelGateway` 构造注入 `ValueListenable<ChatMode> modeSource` + `Llm`，**不直接依赖 SettingsRepository**；
- `ChatMode` 的唯一解析点仍在 `LlmService._mode`（现读设置 + 入口复核），`LlmService` 暴露 `ValueListenable<ChatMode> get mode` 供注入；
- **每轮现选策略**：`converse` 内按 `modeSource.value` 选 `LocalContextPolicy` / `CloudContextPolicy`（两个无状态常量实例），窗口每轮现算，切换下一轮自然生效。

### D3 模式切换时的状态防御：`state.reset()`

两端窗口宽度不同（度量单位、预算都不同），`ContextState.k` 游标跨模式语义会漂。约定：**网关监听模式变更，触发一次 `state.reset()`（保摘要文本、清游标与挤出记账）**——与既有「历史变短 → reset」是同一条防御思路。摘要文本与后端无关，可跨模式保留。

### D4 摘要器统一走 `ask`

现在摘要器的双端差异其实只有「调谁」（云调 BYOK / 本地调引擎）。`Llm.ask` 本就按模式解析后端，故 `ModelGateway` 的摘要器统一为 `SingleShotSummarizer(llm.ask)`，**策略对象里不再有摘要器差异**，`LocalContextPolicy` / `CloudContextPolicy` 只剩度量 + 预算两个纯参数差异。

### D5 补全面：透传纪律 + 输入预算守门

- `ask` / `askJson` / `stop` / `readiness` 在 `ModelGateway` 上是**一行委托**，禁止长出任何逻辑（不持状态、不压缩、不摘要）；
- **新增输入预算守门**（修现网缺口）：守门实现落在 **llm 基建的补全唯一通道**（`LlmService.ask/askJson` 入口，T1；物理文件 `llm/single_shot/input_guard.dart`）——`ModelGateway.ask` 透传 `llm.ask` 自动获得守门，不重复实现。按当前模式选 estimator 度量 `system + user`，超预算抛类型化异常 `GatewayInputOverflowException`；
  - **不做静默截断**（截断 = 提取任务「成功但错误」，无信号）；
  - **不做自愈**（单次调用无可牺牲的历史，抛错交业务降级——如跳过本轮提取）；
  - 度量口径复用现有 estimator：本地 `LlamaTemplateEstimator`（与 `converse` 同 nCtx）、云端 `CharCountEstimator` 对 `cloudInputBudget`。

### D6 不新增中间层

两个门面收敛后不再包装：`ModelGateway`（业务面）+ `Llm`（基建接缝）。透传成本一两行，换业务单一依赖；出现第二个对话类消费者之前不抽象 Gateway 接口。

## 四、接口签名

```dart
/// 业务唯一门面（core/model_gateway.dart，core 根组合层）
class ModelGateway {
  ModelGateway({
    required Llm llm,                              // 基建接缝
    required ValueListenable<ChatMode> modeSource, // 单一模式来源由 LlmService 暴露
  });

  // ── 对话面（有状态；编排装配 → 交付 → 自愈；摘要跨模式保留）──
  Stream<String> converse(
    List<ChatMessage> history, {
    required String systemPrompt,
  }); // 不再收 state——状态是网关私有

  // ── 补全面（无状态透传 + 守门）──
  Future<String> ask({required String system, required String user, int? maxTokens});
  Future<Map<String, dynamic>?> askJson({required String system, required String user, int? maxTokens});

  // ── 通用透传 ──
  void stop();
  bool get isReady;
  ValueListenable<LlmReadiness> get readiness;
}

/// 单次补全输入超预算（fail-fast，业务决定降级）
class GatewayInputOverflowException implements Exception { ... }
```

`Llm` 接口变化：

- **删除 `converse`**（编排移入网关；`ChatGeneration`（原 ChatDelivery）与策略的逻辑保持不变，命名随 D7）；
- 保留 `ask` / `askJson` / `ensureReady` / `stop` / `isReady` / `readiness`；
- `LlmService` 新增 `ValueListenable<ChatMode> get mode`（内部 `_mode` 的可监听化：`backendListenable` 变更时同步写 `ValueNotifier<ChatMode>`）。

类型可见性：业务消费 `readiness` / 模式相关枚举但不许 import `llm/` 下文件——`model_gateway.dart` 统一 **re-export** `LlmReadiness` / `ChatMode`（`export ... show ...`），业务类型可见、实现不可见。

## 五、迁移步骤（小步提交，每步全绿）

1. **T1 守门先行**（独立可交付）：`LlmService.ask/askJson` 加输入预算守门 + `GatewayInputOverflowException` + 单测。此时业务无感。
2. **T2 模式源暴露**：`LlmService` 增加 `mode` ValueNotifier（`_onBackendSettingChanged` / 初始化时写入），暴露 getter。
3. **T3 ModelGateway 对话面**：新建 `model_gateway.dart`——持 `ContextState`、编排 converse（逻辑自 `LlmService.converse` 平移）、模式切换 `reset()` 防御、摘要走 `llm.ask`。`LlmService.converse` 暂留（双轨）。
4. **T4 业务切换**：`ChatProvider` 改依赖 `ModelGateway`（删 `_contextState`）；`chat_page` readiness 消费改走 Gateway；`strategy_brief` 的 `_llm.askJson` 改走 Gateway。
5. **T5 收口**：删 `Llm` 接口的 `converse` 与 `LlmService.converse`；`main.dart` 构造 `ModelGateway` 注入 Provider 树（`Provider<ModelGateway>.value`），清理旧注入。
6. **T6 文档与记忆同步**：更新 `docs/PROJECT.md` 大模型服务分层章节；工作记忆同步分层新约定。
7. **T7 目录重组**（D7）：新建 `core/context/` 域（ContextState 拆分 + Summarizer/度量器改注入）、`core/llm` 按 generation / single_shot / engine 分桶 + 命名对照表全量改名 + 全量 import 修正 + `test/` 同构镜像 + 全绿。纯移动 + 注入改造 + 改名，不改行为。

### D7 目录结构与命名

按**语义域**分桶：上下文管理独立成域，`core/llm` 只留模型服务；门面独立单文件。**文件与目录名直接说人话**——两个执行子域按「多轮流式生成」vs「单次一问一答」命名，不再用 delivery / completion 这类费解词：

```
core/
  model_gateway.dart              # 业务唯一门面（组合层，与 constants/logger 同级）
  context/                        # 上下文管理域（纯语义，零依赖 llm）
    context_state.dart            #   ContextState（压缩状态：游标/摘要/记账）
    context_assembly.dart         #   装配器：过滤 → 度量 → 装窗 → 挤出（共享规则）
    local_context_policy.dart     #   端侧参数档案（预算/最小保留；度量器注入）
    cloud_context_policy.dart     #   云端参数档案
    context_budget.dart           #   预算常量与口径
    summarizer.dart               #   摘要接口 + 提示词（传输实现由门面注入）
  llm/                            # 大模型服务域（纯底座，不知道上下文规则）
    llm.dart                      #   基建接缝接口（ask/askJson/readiness/stop）
    llm_service.dart              #   基建实现（唯一模式解析点 + 生命周期）
    generation/                   #   多轮流式生成段（原 delivery/）
      generation.dart             #     接口（原 chat_delivery.dart，类 ChatGeneration）
      local_generation.dart       #     端侧：会话全量重放（原 local_delivery.dart）
      cloud_generation.dart       #     云端：BYOK SSE（原 cloud_delivery.dart）
      sse_parser.dart             #     SSE 帧解析
      tail_dedup.dart             #     尾部去重（TailDeduplicator）
      think_stream_filter.dart    #     流式 think 过滤
    single_shot/                  #   单次一问一答（原 completion/）
      cloud_request.dart          #     BYOK 非流式请求（原 cloud_completion.dart）
      local_inference.dart        #     端侧单次补全原语（原 inference.dart 的 completeText）
      input_guard.dart            #     新增：ask 输入预算守门（T1 落点）
      think_tag_stripper.dart     #     think 剥离（双路径共用）
    engine/                       #   端侧引擎底座
      llama_service.dart          #     引擎池（幂等 + 并发去重）
      active_model_manager.dart   #     活跃模型变更通知
      llama_template_estimator.dart  #  端侧 token 度量（llama 模板知识；自 local_context_policy 拆出，由门面注入端侧策略）
```

命名对照（旧 → 新）：

| 旧 | 新 | 理由 |
|---|---|---|
| `delivery/`（交付段） | `generation/`（生成段） | 「delivery」看不出在干什么；该段的实际语义是「跑一轮生成」 |
| `ChatDelivery` / `LocalDelivery` / `CloudDelivery` | `ChatGeneration` / `LocalGeneration` / `CloudGeneration` | 随目录同步 |
| `completion/` | `single_shot/` | 「completion」易与补全 API 混淆；「单发」与对流式生成的对照一目了然 |
| `cloud_completion.dart` | `cloud_request.dart` | 类 CloudCompletion → CloudCompletionRequest |
| `inference.dart` | `local_inference.dart` | 「推理」不标注端侧会误读为通用原语 |

命名原则：**目录名 = 该目录回答的问题**（generation 回答「流式怎么跑」，single_shot 回答「一问一答怎么发」，engine 回答「引擎怎么管」）；类名随文件走；`ChatMessage` / `AssembledContext` 等既有数据类型不动。

依赖方向（单向，禁环）：

- `context` **不依赖 `llm`**：摘要传输用 `Summarizer` 接口表达，实现（`llm.ask` 包装）与端侧度量器均由 `ModelGateway` 构造时注入；
- `llm` **不依赖 `context`**：纯后端底座；
- `ModelGateway` → `context` + `llm`：唯一的组合点（编排装配/压缩/自愈 + 策略组装 + 补全守门透传）；
- 业务 → `ModelGateway`（唯一入口），不 import `context` / `llm` 类型。

`test/` 目录同构镜像。

## 六、测试影响

- 现有 `LlmService` 编排类单测（装配 → 生成 → 自愈）**平移**到 `ModelGateway` 测试（fake `Llm` + fake 策略/生成接缝不变）；
- 新增：模式切换触发 `reset()` 的用例（切换后首轮窗口重算、摘要保留）；
- 新增：`ask` 守门用例（本地超 1668 token 抛异常 / 云端超 60000 字符抛异常 / 边界内正常）；
- `test/support/fake_llm.dart` 增补 `FakeGateway`（或让 fake 实现 Gateway 的对话面）。

## 七、范围外（明确不做）

- 不改 `ChatGeneration`（原 ChatDelivery）/ 策略 / 溢出自愈的**逻辑本身**（命名与归属随 D7 调整）；
- 不改 BYOK、推送、提取业务逻辑；
- 不引入 grammar / `response_format` 硬约束；
- Gateway 不做接口抽象（单实现）。
