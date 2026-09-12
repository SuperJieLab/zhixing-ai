# 知行AI — 大模型服务分层（Llm Service Layering）

> 状态：**设计已确认**（2026-09-12；两轮设计讨论 + 一轮源码级复核；**§10.1 三项开工前待拍已全部拍定**；代码未动）
> 复核：§11 末「复核记录」列出 13 条自检结论（5 条为实质修正），本文所有行号引用均已回源码核对
> 前置：`2026-09-11-context-policy-design.md`（ContextPolicy 已落地）、`2026-09-11-local-stateless-replay-design.md`（端侧无状态重放已落地）
> 依据：`docs/notes/2026-09-11/local-kv-reuse-feasibility.md` **§11**（业界职责归属对照）；讨论结论与源码核实见 `.workbuddy/memory/2026-09-11.md`
> 讨论纪律（本轮固定）：**先摆结构 → 再标差异 → 最后分家**；不同层级的东西不并列。骨架下的调优项统一进 **§11 附录**，不进主结构。

## 1. 背景与问题

### 1.1 触发：三处大模型调用点，姿势各不相同

| 调用点 | 形态 | 后端怎么定 | 重复了什么 |
|---|---|---|---|
| 对话 | **多轮** | `ChatProvider._resolvedMode`（`:132-136`）读 `SettingsRepository.chatCloudMode` → 选 `CloudChatClient` / `LocalChatClient` | — |
| 压缩（摘要） | 单轮 | **不读配置**：「谁构造 client 就用谁」→ 隐式正确 | 单次补全样板、事件循环 |
| 目标提取 | 单轮 | **不读配置**：`strategy_brief_provider.dart:142-145` 直接 `LlamaService.instance.ensureReady(...)` | 单次补全样板、事件循环、**自写装箱** |

三处重复（带行号）：

| # | 重复 | 位置 |
|---|---|---|
| 1 | 单次补全样板（`createChat → addSystem → addUser → generate → 事件循环 → stripThinkTags → dispose`） | `local_context_policy.dart:34-56`（23 行）、`strategist_extractor.dart:100-144`（约 25 行） |
| 2 | 事件循环 `if (event is TokenEvent)` | `local_chat_client.dart:41-49`（已是纯函数）、`local_context_policy.dart:46-51`、`strategist_extractor.dart:106-117` |
| 3 | 尾优先装箱 | `context_policy.dart:117-139`（`packTailWithinBudget`）vs `strategist_extractor.dart:148-166`（`_truncateMessages`） |

两条**口径不一致**：

- 提取用裸 `LlamaService.estimateTokens`（无模板开销），chat 侧用 `LlamaTemplateEstimator`（`+16/条`）→ 同一个物理窗口两套账，提取侧算得偏乐观。
- `DoneEvent.trailingText` 已在 `eventsToText`（`:41-49`）修好，但另两处仍是旧写法 → **同一个坑只修了 1/3**；提取器若丢尾字符，`jsonDecode` 可能直接失败。

### 1.2 一处真实缺陷（不只是美学）

> 用户在设置页开启云端模式、**未下载本地模型** → 进入 strategy_brief → `ensureReady()` 抛错 → `BriefStatus.error`（`:174-179`）。

「我明明选了云端，你还让我下 2B 模型」——违背用户意图，且触发路径完全正常。

### 1.3 与骨架的五处错位

| 骨架要求 | 现状 |
|---|---|
| **J1** 单一模式来源 | **两份**：`ChatProvider` 读配置；`StrategyBriefProvider` 不读、硬编码本地 |
| **J2** 统一入口 | **无**。业务直接摸 `ChatClient` / `LlamaService` |
| 转换在基建 | 在 `features/chat/engine/context/`，且**带着状态实例**（`BaseContextPolicy._summary/_retained/_consumed`） |
| 交付是清晰接口 | 有接口但**绑了「对话」语义**：`ChatClient.generateResponse(history)` 一个方法同时表达「装配」与「交付」 |
| 取回共享 | `eventsToText` 在 chat 内 → strategy_brief 跨 feature 无法引用，各自重写 |

## 2. 已确认决策

| 决策点 | 结论 |
|---|---|
| 模式来源 | **全 App 单一来源**，由一份用户配置唯一决定 |
| 业务适配 | **所有业务场景天然适配两种状态**，不存在「某场景只能用本地/云端」的例外 |
| 提取是否跟随配置 | **跟随**（与对话、摘要一致） |
| 基建是否持状态 | **不持业务语义状态**；但**持服务资源状态**（引擎句柄 / 加载态 / 当前模式）——见 §6.5 |
| **压缩归属** | **无业务差异**：机制通用（基建）＋ 参数按**后端**（度量 / 预算 / 保底条数 / 溢出收缩 / 摘要模型）→ 业务输入为 **0**（逐项拆解见 §5.1） |
| 摘要提示词归属 | **后端（模型能力）差异**，非业务差异 → 基建给**默认实现 + 单一覆盖点**（App 级，**不按 feature 各写一份**） |
| 实例形态 | **方案 B：实例唯一 + 构造注入**——唯一性来自「只有一个构造点」，业务依赖**接口**，不写 `.instance` |
| 讨论层级 | **只谈骨架**；细节是骨架下的微调 |
| ~~约束参数 `requiresLocal`~~ | **作废**——既然不存在例外场景，入口不需开口子表达约束 |

## 3. 骨架

### 3.1 三层（空间）

| 层 | 持有什么 | 给什么 |
|---|---|---|
| **业务层** | 消息列表（唯一真相源）、压缩状态**实例** | 人设文案；**压缩无业务参数**（见 §5.1） |
| **基建层**（`core/llm`） | 引擎句柄、加载态、当前模式；四段流水与装配算法 | 类型定义、默认实现、统一入口 |
| **后端** | 端侧 llama 引擎 / 云端 BYOK 端点 | 差异被关在这里（业务不可见） |

### 3.2 基建内部四段（流程）

```
入口 ──▶ 转换 ──▶ 交付 ──▶ 取回
```

| 段 | 职责 | 差异落点 |
|---|---|---|
| **入口** | 解析模式（**唯一**）+ **确保就绪** + 施加各段 | 无差异（按配置） |
| **转换** | 过滤 → 装窗 → 压缩（内含**度量**） | **全部按后端**（度量 / 预算 / 保底条数 / 溢出收缩 / 摘要模型）；**无业务差异**（见 §5.1） |
| **交付** | 把装配结果送进模型执行 | **两端形状真正不同**（见 §5）——唯一需要「接口 + 双实现」处 |
| **取回** | 事件流 → 文本流（+ think 剥离） | 无差异（共享） |

### 3.3 三关节（需要拍的结构决定）

| 关节 | 内容 |
|---|---|
| **J1 单一模式来源** | 全 App 只有一处能回答「现在是本地还是云端」；任何地方想判断模式都必须问它。直接消灭 §1.2 那类 bug——不是修一次，而是让它无法再发生 |
| **J2 统一入口形状** | 业务只有两个**完整动作**：要一轮对话 / 要一次补全。**不是钩子、不是「只选后端的通道」**——只有完整动作能把业务侧压到零分支 |
| **J3 状态归属** | **类型在基建、实例在业务**（见 §4） |

### 3.4 服务（唯一实例）的三条职责

1. **启动时初始化环境**（App 启动点构造并触发初始化，异步不卡首帧）
2. **监听/判定模式并切换服务**（切本地 → 加载；切云端 → 延迟释放并防抖）
3. **向业务提供能力**（`converse` / `ask` / `askJson`）

> 这三条都要求一个**跨业务生命周期的宿主**，故「服务」是必需的一层，不是包装。

## 4. 边界判据（可复用）

| 判据 | 说明 |
|---|---|
| **位置 ≠ 性质** | 「它现在住在哪个目录」不能作为归属理由（本轮两次踩坑：`buildSummaryPrompt`、`BaseContextPolicy`） |
| **类型定义权归机制，实例持有权归生命周期** | 压缩机制决定它必然需要「摘要 + 覆盖到哪一条」→ 类型进基建；谁 new / 谁存 → 业务 |
| **抽象只出现在差异点上** | 无差异处直接共享代码，不为对称而造抽象 |
| **统一入口给完整动作** | 给「一轮对话 / 一次补全」，不给碎片钩子；可组合性藏在内部 |
| **屏蔽 ≠ 消除** | 差异一个都没少，只是关进基建、有了唯一表达位置；「抽了一层差异就没了」是错觉 |
| **自检判据** | 塞进**第三个后端**，需改动的文件集合是否**只落在基建内**（唯二例外：配置键 + 设置页开关）？是 → 骨架正确 |

## 5. 六处物理不对称的归属

| 维度 | 端侧 | 云端 | 骨架定位 |
|---|---|---|---|
| 度量单位 | token（模板规则） | 字符（近似） | **基建**（转换段，接口 + 双实现） |
| 预算值 | 1668 | 60000 | **基建**（同度量一起走） |
| **交付方式** | 数据**进对象**（会话重放） | 数据**进请求**（HTTP SSE） | **基建**（交付段，接口 + 双实现）——唯一形状差异 |
| 输出结构遵从度 | 固定 2B，可针对性调 | 用户自选模型，不可控 | 骨架下**调优项**（见附录 A1） |
| 调用成本 | 电费 | 用户的钱 | 骨架下**产品优化项**（A2） |
| 引擎生命周期 | 需加载/释放 | 无需 | **基建**：「确保就绪」是**入口**的职责 |

> 「交付」精确定义：**把装配好的输入上下文，交给模型去执行的那一步**。云端它是 HTTP 请求体里的一个字段（`messages: [...]`），无状态一次性；端侧**没有「发送消息」API**，必须把消息推进活着的会话对象（`addSystem/addUser/addAssistant` + `generate()`）。⇒ 云端 = 数据进请求，端侧 = 数据进对象。

### 5.1 压缩：逐项归属（无一项属业务）

| 决策项 | 因什么而变 | 归属 |
|---|---|---|
| 何时压（触发：用量 vs 预算） | 派生自度量 + 预算 | 基建（通用机制） |
| 丢哪些（尾优先装箱；保底条数） | 保底条数按后端 | 基建（机制 + 后端参数） |
| 摘要卡装配 / 文案前缀 / 200 字上限 | 不变 | 基建 |
| 摘要由哪个模型生成 | 后端 | 基建（后端策略） |
| **摘要提示词** | 模型能力（≈后端） | 基建默认 + **单一**覆盖点 |

**⇒ 业务场景输入 = 0。** 业务的职责只有两件：**传消息列表**；**持压缩状态实例**（摘要正文 + 覆盖游标）。

> **现状即证据**：`ChatProvider` 只传消息列表，对压缩零输入；policy 由 client 自己 `new`（`minKeep` / `overflowKeep` / `summaryCharLimit` 全在两端各自写死）；`LocalChatClient` 的 `policy` / `summarizer` 构造参数**只被测试用到**（`local_chat_client_test.dart:104`、`cloud_chat_client_test.dart:309`）——`lib/` 里没有任何一处业务注入压缩策略。

**一个真实的业务级压缩需求会长什么样（现在都不存在）**：① 保留白名单（「压缩时别丢用户说过的目标」）；② 摘要口径特化（「学习场景要保留困惑点与进度」）。

- ①在本 App 已被**另一个机制**满足：目标由 `StrategistExtractor` 抽成 `StrategyBrief` 单独存储，并经 `buildSystemPrompt(existingGoals:)` 每轮重新注入人设 → 压缩丢掉原文不影响目标可见性。
- ②在本 App 里是 **App 级口径**（只有一个对话业务），不构成「某个 feature 的定制」。

⇒ **留覆盖点（= 可扩展），不留 per-feature 注入义务（= 单场景定制先不动）**。

> **修正记录**：草案 §3.2 曾写「压缩实现由业务注入」——那是「摘要提示词属后端差异」那次修正的**残留**（只改了 §2，未回改 §3.2/§3.1/§6.1）。现按上表逐项拆解更正。判据提醒：**「需要注入」不等于「必须由业务定义」**——本节所有注入点的主语都是**后端**。

## 6. 接口与代码形态

### 6.1 业务依赖面（唯一）

```dart
// core/llm/llm.dart —— 业务只认这个接口
abstract class Llm {
  /// 一轮对话：给完整历史，回文本流（think 剥离策略见 §10.1 #5）。
  /// 第二参数形态待 §10.1 #7（若 `nudgeTail` 不进 spec，`ConverseSpec` 只剩人设，
  /// 可能直接退化为 `required String systemPrompt`）。
  Stream<String> converse(List<ChatMessage> history, {ConverseSpec? spec});

  /// 一次补全：给 system + user，回一段文本（内部收流、剥 think）。
  Future<String> ask({required String system, required String user, int? maxTokens});

  /// 一次补全的**结构化输出契约**（已拍定，见 §10.1「已拍定」#6）：
  /// 内部施加 JSON-only 约束 + 剥围栏 / 刮第一段 `{...}` + `jsonDecode`。
  /// 返回 null = 模型没能给出可解析 JSON（调用方按「无内容」处理）；请求失败仍抛异常。
  Future<Map<String, dynamic>?> askJson(
      {required String system, required String user, int? maxTokens});

  /// 中断进行中的对话流。
  void stop();

  /// 当前后端是否就绪（供 UI 表达，**不暴露**「本地/云端」）。
  bool get isReady;
}
```

`ConverseSpec` = 业务注入口（值对象）：**人设文案**（`spec` 的参数形态见 §10.1 #7）。**压缩参数不在其中**——度量 / 预算 / 保底条数 / 溢出收缩 / 摘要模型全部按后端解析（§5.1）；摘要提示词的覆盖是一个 **App 级配置**，不经由 `ConverseSpec` 逐 feature 注入。

> **复核后撤下的一项**：首稿曾把「尾部去重改写开关」（`nudgeTail`）列进 `ConverseSpec`。但它是 `_syncSession` 的内部自愈细节（`local_chat_client.dart:249-274`），业务对它没有语义——把它暴露给业务，与 §4「统一入口给完整动作、不给碎片钩子」直接冲突。现改判为**交付实现内部状态**（连带 `isDuplicate` 归属，见 §10.1 #7）。

> 命名说明：`converse` 描述**调用形状**（整段历史），`ask` 描述**一次提问**。`complete` 被否——它描述实现动作而非调用形状。（`ask` 为暂定名，见 §10.1）

### 6.2 `LlmService`（实现 + 内部编排）

无 `static instance`；持资源态（引擎句柄 / 加载态 / 当前模式）；内部编排四段。**转换与装配算法在这里，状态实例不在**。

### 6.3 启动点接线（`main.dart`）

```dart
// main() 是 composition root：全 App 唯一的构造点
final llm = LlmService(settings: SettingsRepository.instance);
unawaited(llm.initialize());            // 异步，不卡首帧
runApp(MultiProvider(providers: [
  Provider<Llm>.value(value: llm),      // ← 唯一实例由这里持有
  ChangeNotifierProvider<ActiveModelManager>.value(value: ActiveModelManager.instance),
], child: ZhixingApp(navigatorKey: navigatorKey)));
```

**唯一性来源**：不是 `static`，而是「`main()` 只跑一次、只 `new` 一次」+ App 级 Provider 树持有（寿命与 App 相同）。防绕过：实现类不与接口同库导出，公开面只留接口 + 单一工厂。

### 6.4 业务侧写法（现状 → 目标）

| 业务 | 现状 | 目标 |
|---|---|---|
| `ChatProvider` | 读配置 → 判断云端/本地 → 校验 → 加载模型 → new client → 组人设 → `generateResponse` | 持消息列表 + 持压缩状态实例 + `llm.converse(messages, spec: ...)` |
| `StrategyBriefProvider` | `LlamaService.instance.ensureReady()` → new extractor（**硬编码本地**） | `llm.ask(system:, user:)` |

### 6.5 状态三分

| 种类 | 例子 | 归属 |
|---|---|---|
| **业务语义状态** | 消息列表、压缩状态（摘要 + 覆盖游标） | **业务** |
| **服务资源状态** | 引擎句柄、加载态、当前模式 | **服务** |
| 业务内容（非状态） | 人设、业务指令 | 业务提供 |

> 判据：**服务不持它，能不能正确工作？** 引擎句柄不持 → 无法加载释放，故必须自持；消息列表不持 → 每轮传入照样工作，故留业务。

## 7. 迁移映射

| 现状 | 去向 |
|---|---|
| `features/chat/engine/client/chat_client.dart` | **交付接口**（`ChatClient` 退化为「怎么交付」，不再含「对话」语义），进基建 |
| `…/client/local_chat_client.dart`（`_syncSession` 清空+重放） | 端侧**交付实现**，进基建；`ChatSession` / `ChatSessionFactory` 测试接缝随之 |
| `…/client/cloud_chat_client.dart`（SSE） | 云端**交付实现**，进基建；`ChatMode` enum（`:14`）随之搬走 |
| `…/context/context_policy.dart`（装配算法） | **转换段**，进基建；`BaseContextPolicy` 的 `_summary/_retained/_consumed` **不跟随**（状态外置）；按 §10.1 #4 拍定 A，外置后的状态形态为 `{摘要, 覆盖游标 k, 上次 eligible 长度}` |
| `…/context/local_context_policy.dart` | 端侧**后端策略**（度量 + 预算 + 摘要实现），进基建；`LlamaSummarizer` 改用单次补全原语 |
| `…/context/cloud_context_policy.dart` | 云端**后端策略**，进基建；`CloudSummarizer` 的 Dio POST + `_extractContent`（`:67-109`）抽为云端**单次补全** |
| `…/prompt/conversation_strategy.dart` | **三分**：`buildSystemPrompt`（人设）留 feature；`buildSummaryPrompt`（模型能力差异）进基建，覆盖点为 **App 级单一**；**`isDuplicate`**（`:12-26`，**有状态**去重窗口）归属**待定 → §10.1 #7**（它只被端侧交付调用 `local_chat_client.dart:266`，交付下沉 core 后若把它留在 feature 会造成 core→feature 反向依赖） |
| `core/llm/llama_service.dart` | 引擎池 + `estimateTokens` **保留在 core**，成为服务内部细节 |
| `features/strategy_brief/engine/strategist_extractor.dart` | 删 `_truncateMessages`（用共享装箱）、单次补全降为一行、**后端跟随配置** |
| `core/llm/{llm,llm_service,inference,context_budget,context_assembly}.dart` + `core/llm/delivery/` | **新增**（接口 + 服务 + 原语 + 交付双实现） |

⇒ `features/chat/engine/` 目录**解体**：`client/`→交付、`context/`→转换、`prompt/`→留业务。`ChatProvider` 最后只剩「持状态 + 调 `converse`」。

## 8. 不变量与红线

| # | 不变量 | 可验证方式 |
|---|---|---|
| 1 | **单一模式来源**：**判断**模式（`ChatMode` 枚举 / 读 `chatCloudMode`）只在基建；设置页只**写**布尔配置、不做判断 | `grep -rn "ChatMode" lib/features` 为空；且 `grep -rn "chatCloudMode" lib/features` **只命中 `features/settings/`**（不能要求整体为空——设置页必须能写，见复核记录 R2） |
| 2 | **业务零后端分支**：业务文件不出现 `LlamaEngine`、不出现 LLM 语义的 `Dio` | `grep -rn "LlamaEngine" lib/features` 为空；`grep -rln "Dio" lib/features` **只命中 `model_manager/`**（模型下载用的 Dio，与 LLM 后端无关——见复核记录 R3） |
| 3 | **业务语义状态不进 `core/`**：core 无消息列表字段、无摘要正文实例 | 代码评审 + `grep` 测试 |
| 4 | **服务不持消息列表**：`converse` 的历史每轮由业务传入 | 同上 |
| 5 | **交付差异只在交付实现内**：加第三个后端只改基建文件 | 自检判据（§4） |
| 6 | **`.instance` 只在启动点出现**：业务经注入拿到 `Llm` | `grep -rn "LlmService" lib/features` 为空 |
| 7 | **人设不出 feature**：`buildSystemPrompt` 留在业务侧 | `grep` 确认基建不引用它 |
| 8 | **压缩无业务参数**：业务文件不出现压缩内部概念 | `grep -rn "ContextPolicy\|ConversationSummarizer" lib/features` 为空 |

## 9. 行为变更

| # | 变更 | 说明 |
|---|---|---|
| 1 | **提取跟随配置** | 云端模式下提取走云端模型 → 需 JSON 容错（附录 A1；**落点已定 = `askJson`**），否则是**降级**不是升级 |
| 2 | 提取口径统一 | 装箱改用带模板开销的度量 → 预算更紧但正确 |
| 3 | `trailingText` 补齐 2 处 | 提取器/摘要器不再丢尾字符（提取器尤其：影响 `jsonDecode`） |
| 4 | **引擎由服务驱动加载** | 切本地 → 主动加载；切云端 → 延迟释放（防抖）；冷启动 → 异步加载不卡首帧；进会话未就绪 → 异步兜底。原 `ChatProvider.loadModel()` 与 UI loading 的耦合解除 |
| 5 | `ChatProvider.isModelLoading` 语义变化 | 由服务「是否就绪」表达，页面不再自己驱动加载 |
| 6 | （待定）云端回复是否也剥 think | 现云端**不剥**、端侧剥。统一后可能出现行为差异，见 §10.1 |

## 10. 待定项与风险

### 10.1 开工前需拍

| # | 待定 | 选项 |
|---|---|---|
| 1 | ~~模式变更的通知源~~ **已拍：仓库加窄 `Listenable`（方案 ii）+ 入口复核** | 详见下方「已拍定」。仓库现状**无任何事件源**（`SettingsProvider.notifyListeners()` 是 feature 层手动通知，与服务无关） |
| 2 | 命名 | `ask` 暂定；备选 `oneShot` / `runPrompt` |
| 3 | 云端 JSON 容错强度 | 提示词加 JSON-only 约束 / 刮出第一段 `{...}` / 失败重试一次——做到哪一档 |
| 4 | ~~保留窗口：存下来 vs 算出来~~ **已拍：方案 A —— 只存游标 `k`，窗口每轮现算** | A = `{摘要, 覆盖游标 k, 上次 eligible 长度}`（k 即窗口起点下标）；B = `{摘要, 保留窗口列表}`（现状 `_retained`）。**二者可证等价**（窗口恒为 `eligible` 的后缀 ⇒ 一个下标即可表达），详见下方澄清。A 必须同时保留两处防御：① `eligible.length` 比上次**变短** → `reset()`；② 游标越界 → `reset()` |
| 5 | 云端是否也剥 think | 与端侧统一（推荐）还是保持现状 |
| 6 | ~~`ask` 返回形态 vs A1 容错~~ **已拍：方案 A —— 结构化变体 `askJson`** | 详见下方「已拍定 #6」 |
| 7 | **`isDuplicate` 归属 + `nudgeTail` 去留** | `ConversationStrategy.isDuplicate`（`:12-26`）**有状态**（滚动窗口，命中不写入），只被端侧交付调用（`local_chat_client.dart:266`）。交付下沉 `core/llm/delivery/` 后：留 feature → **core→feature 反向依赖**（违反不变量 2 的精神）；下沉交付层 → 需一并决定 `nudgeTail` 是交付内部状态（**推荐**）还是 `ConverseSpec` 参数（首稿写法，已撤） |
| 8 | **`ChatClient.initialize({existingGoals})` 的去向** | 现状 goals 由 `initialize` 一次性注入并被 client 持有（`chat_client.dart:12`、`local_chat_client.dart:134-146`）。目标形态下人设走 `spec` **每轮传入** → 该接口应消失；由此 **Dashboard 的 goals 取用必须留业务**（`chat_provider.dart:117` 的 `getActiveGoals()`），否则 core 反向依赖 Dashboard 仓库。连带未定：`_modelError` / `retryLoadModel()` / `_generateMockResponse()`（mock 兜底）的归属 |

> **开工前须拍**：**已全部拍定**——#1 / #4 / #6 见下；#2 / #3 / #5 / #7 / #8 可在对应 Task 内定。可开工。

**已拍定（2026-09-12）**

- **#6 → 方案 A：结构化变体 `askJson`**（签名见 §6.1）。同一个「一次补全」动作的两种输出契约：`ask` = 纯文本，`askJson` = 结构化。
  - 为什么是独立方法而不是 `ask(json: true)`：两者**返回类型不同**（`String` vs `Map?`），同一签名只能退化成动态类型——那是拿类型安全换一个 bool 参数，不划算。
  - 顺带解决附录 A1 的落点：剥围栏 / 刮第一段 `{...}` / 可选重试**全部落在 `askJson` 内部**，调用方只看到 `Map?`。null = 模型确实没给出可解析 JSON，与「请求失败抛异常」区分开——这正是提取器现有语义（`null` → `noContent`）。
- **#1 → 给 `SettingsRepository` 加窄 `Listenable`（方案 ii），并保留入口复核**。
  - **通知范围**：只在**影响后端的写入**后触发——`setChatCloudMode` + `setCloudApiBaseUrl` / `setCloudApiKey` / `setCloudModelName`（后三个改了，云端交付实现必须重建，否则继续用旧 Key）；其余设置项不通知。
  - **服务侧**：订阅后判定「需要的后端（或云端三件套指纹）≠ 当前」→ 切换 / 重建，切换走**延迟释放 + 防抖**。
  - **与「入口惰性判定」不是二选一**：通知是**触发源**（让「切云端立刻延迟释放」成立），入口复核是**兜底**（漏通知 / 服务未及时响应也不至于用错后端）。原先把二者并列成 (i)/(ii) 是伪选择。
- **#4 → 方案 A：状态只存游标 `k`，保留窗口每轮现算**（详见下方澄清）。
  - 状态形态：`{摘要, 覆盖游标 k, 上次 eligible 长度}`——窗口 = `eligible[k..]`，是**派生量**而非需要维护的真值。
  - **必带两处防御**（否则与 B 不等价）：① `eligible.length` 比上次**变短** → `reset()`（覆盖「中间删消息」）；② 游标越界 → `reset()`。
  - **等价性验收**：用现有 `context_policy_test.dart` 的压缩 / 自愈用例跑绿即视为等价；若出现不等价先例，回退 B（即维持 `_retained` 列表）。

**澄清（#4，已拍定方案 A）：「每轮重算切点」不是另一套压缩策略**

先纠正措辞：这不是「两种压缩策略」，而是**同一套压缩策略下，保留窗口要不要被存下来**。触发条件、挤出规则、摘要口径、`minKeep` / `overflowKeep`，A / B 完全一样。

- **B（现状，`context_policy.dart:168-204`）**：窗口 `_retained` 是一份**被记住的列表**。每轮靠 `_consumed` 游标把新增消息追加进去，再对**这个窗口**跑尾优先装箱；超预算 → 挤出前端 + 出摘要 → 窗口缩回预算内 ⇒ **后续若干轮不再触发压缩**（代码注释 `:169-171` 明说这是为了「避免每轮都调一次摘要器」）。
- **A（每轮重算切点）**：不记列表，只记「窗口从哪条开始」——一个下标 `k`。每轮拿**全量 eligible** 从尾部往前装箱，算出的 `cut` 就是新的窗口起点。

**为什么可证等价**：跟踪 `_retained` 的演化——初始为空；每轮在尾部追加 eligible 的增量；挤出时 `_retained = pack.kept`，而 `pack.kept` **恒为 `eligible` 的后缀**（`packTailWithinBudget` 从尾部累加，`packKeepLast` 取最后 N 条）。⇒ 归纳可得：任何时刻 `_retained ≡ eligible[k..]`，**窗口永远是全量列表的一条后缀**。既然它恒为后缀，「记住整个列表」和「记住起点下标」表达的是同一件事——所以 A 不是新策略，只是把状态从**列表**换成**整数**。

**A 的收益**：状态小到可序列化（`{摘要, k, 上次长度}`），将来能持久化 / 随会话迁移；窗口从「需要维护的真值」降级为「每轮现算的派生量」，少一处可能与消息列表漂移的副本。

**A 的代价（必须一起处理，否则不等价）**：现状拿 `_consumed`（上一轮长度）与 `eligible.length` 比较，能天然发现**任何历史变短**（一缩就 `reset()`）；只存下标 `k` 时，中间删掉一条可能**不越界**，窗口静默错位一位（把已折进摘要的一条又拉回来）。⇒ 选 A 必须同时保留 ①「长度比上次变短 → `reset()`」②「游标越界 → `reset()`」两条防御。等价性可用现有 `context_policy_test.dart` 的压缩 / 自愈用例验证。

**决定（2026-09-12）：取 A。** 理由：状态可序列化（窗口是派生量，少一处与消息列表漂移的副本）；代价侧的两条防御明确、可控，且有现成用例可验等价。若验收发现不等价且修复成本高，再回退 B——回退是**局部**（状态表示）而非结构性的。

### 10.2 风险

- **范围大**：这是项目至今最大的一次结构改动，`features/chat/engine/` 整体解体。必须 strangler 式分步（见 plan），每步绿。
- **状态外置是实打实的改造**（非 `git mv`）：`BaseContextPolicy` 的三个状态字段要改为「业务持有 + 每轮传入」；按 #4 拍定的 A 形态，`_retained`（列表）被 `k`（下标）替代，`_consumed` 的「上轮长度」降级为防御用的比较值。
- **云端 JSON 遵从度未知**：BYOK 用户自选模型可能加围栏/解释文字；现容错只有 `catch → return null`。
- **云端模式下后台调用产生费用**：提取/摘要是后台自动触发，用户不会主动点。
- **引擎生命周期收口牵动 UI**：`isModelLoading` 现在驱动整页 loading（`chat_page.dart:118-119`）。
- **测试改写面大**：三个策略测试 + 两个 client 测试都要迁移、都要动。**注意「提取器测试」并不存在**——`test/` 下既无 `strategist_extractor_test.dart` 也无 `StrategyBriefProvider` 的测试（`StrategistExtractor` 现持 `LlamaEngine`，无 fake 接缝）。plan Task 1 要补的提取器用例是**新建**，且须等 Task 2 把它改为依赖 `Llm` 后才可注入 fake。
- **冒烟不可自动化**：真机/模拟器验证项见 plan Task 5。

## 11. 范围外 + 附录

**明确不做**

- **钩子化 / 链路骨架**：已核算——三个调用点只有 1 个需要压缩编排，差异点只有 2 个（度量、摘要器）且已由注入表达；钩子化只增加文件与测试，收益为零。
- 不改 `ContextPolicy` 的**装配算法**（只搬位置 + 状态外置）。
- 端侧 KV 复用（`local-kv-reuse-feasibility.md` §1–§9，结论不变）。
- 多后端并行 / 自动降级链（无需求）。
- 服务端任何改动。

**附录：骨架下的调优项（不进主结构）**

| # | 项 | 说明 |
|---|---|---|
| A1 | 云端输出结构容错 | 提示词 JSON-only 约束 + 解析容错（剥围栏 / 刮第一段 `{...}`）+ 可选重试。**落点已定**：全部在 `askJson` 内部（§10.1 已拍定 #6），调用方只见 `Map?` |
| A2 | 成本知情 | 设置页一句说明：「云端模式下，后台的摘要与目标提取也会调用你配置的模型」 |
| A3 | 加载策略参数 | 延迟释放的防抖时长、冷启动异步加载的优先级 |
| A4 | 提示词微调 | 摘要/提取提示词按模型能力分档（2B vs 云端大模型） |
| A5 | `ChatSession` 更名 | `LocalChatClient` 下沉后其命名语境消失，可顺势改为交付语义的名字（本轮不动） |

**复核记录（2026-09-12 二轮自检：逐条回到源码核对）**

**先说结论：本文引用的行号 / 类名 / 文件路径，12 处抽样全部命中，无编造。** 但发现 4 处**实质性不一致**与若干表述硬伤，均已按上表修正：

| # | 发现 | 处理 |
|---|---|---|
| R1 | 引用准确性抽查全部命中：`eventsToText:41-46`、`ContextEstimator:83-93`、`ConversationSummarizer:96`、`packTailWithinBudget:117-139`、`packKeepLast:145-158`、`LlamaSummarizer.summarize:34-56`、提取器样板 `:100-144` / 事件循环 `:106-117` / `_truncateMessages:148-166`、`CloudSummarizer Dio+_extractContent:67-109`、`ChatMode:14`、测试注入点 `:104`/`:309`、`strategy_brief_page.dart:23`、`chat_page.dart:119`、`main.dart` 的 `MultiProvider` | 无需改 |
| R2 | **不变量 1 的 grep 断言原样永远不成立**：设置页必须能**写**模式（`settings_provider.dart:44`、`settings_page.dart:78` 都在 features 下），改造后仍会在。根因是原表述把「**读/判断**」和「**写**」混为一谈 | 不变量 1 已改为「判断不出 features + 写只命中 `settings/`」；§8 表格补「判断 vs 写」 |
| R3 | **不变量 2 的 grep `Dio(` 原样就不为空**：`model_manager/engine/model_download_service.dart:20` 有模型下载用的 `Dio`（与 LLM 后端无关）——一个号称"机器可查"的证据其实查不过 | 已限定为「`LlamaEngine` 为空 + `Dio` 只命中 `model_manager/`」 |
| R4 | `ConverseSpec` 里的 `nudgeTail` 是交付层的机制细节，业务无语义，与 §4「不给碎片钩子」冲突 | 已撤下 → §10.1 #7 |
| R5 | **§7 拆分清单漏 `isDuplicate`**：它是**有状态**的机制件，只被端侧交付调用；交付下沉 core 后若把它留在 feature，就是 core→feature 反向依赖（违反不变量 2 的精神，且 grep 抓不到） | 已补进 §7 + §10.1 #7 |
| R6 | **A1（容错）与 `ask` 返回形态互斥**：容错要求结构化返回，而 §6.1 是 `Future<String>`；plan 却把 A1 列为 Task 2 不可分割 → 无法同时满足 | 新增 §10.1 #6；**同日已拍定：方案 A（`askJson`）** |
| R7 | **`ChatClient.initialize({existingGoals})` 两份清单都没提**：目标形态下人设走 `spec` 每轮传，该接口应消失；连带 `_modelError` / `retryLoadModel()` / `_generateMockResponse()` 归属未定 | 新增 §10.1 #8 + plan Task 4 补注 |
| R8 | §10.2 提到「提取器测试」——**该测试文件不存在**（`test/` 下零覆盖 `StrategistExtractor` / `StrategyBriefProvider`），故"都要动（含迁移）"是错的 | 已更正：改为"**新建**"，并注明须先有 `Llm` 注入点 |
| R9 | §6.1 注释写「think 已按配置剥离」，与 §9.6 / §10.1 #5「云端是否剥 think 待定」自相矛盾 | 注释改为指向 §10.1 #5 |
| R10 | §7「新增」清单漏 `llm_service.dart`（§6.2 明确存在）与 `delivery/`（plan Task 3 使用） | 已补 |
| R11 | `converse(List<ChatMessage>, {ConverseSpec spec})` 在 Dart 中非法（非空命名参数无默认值） | 已改 `ConverseSpec?`；参数形态归 §10.1 #7 |
| R12 | §4 自检判据「只落在基建内」过强：新增第三个后端必然要动配置键与设置页开关 | 已加"唯二例外"限定 |
| R13 | 三项开工前待拍（**#1 / #4 / #6**）已于 2026-09-12 全部拍定：`Listenable`+入口复核 / A（只存游标 `k`）/ `askJson` | §10.1 表格标「已拍」+「已拍定」小节；plan 头部「可开工」 |
| R14 | 三轮复核（拍定 A 之后）：**全部行号引用二次回源码命中**（含 `ChatMode:14`、`cloud_context_policy.dart:67-109`、测试注入点 `:104`/`:309`、`isDuplicate:12-26`、`_syncSession:249-274`、`_resolvedMode:132-136`、`BriefStatus.error:174-179`、`is TokenEvent` 恰 3 处、测试基线 177）；发现 plan Task 1 的 `completeText` 伪码**命名参数无默认值（非法）**——与 R11 同类错误第二次出现 | 伪码改 `int? maxTokens, bool stripThink = false`；Task 1 item 4 与签名对齐（`stripThink: true`，不再手写 strip）；§3.4 能力清单补 `askJson` |
