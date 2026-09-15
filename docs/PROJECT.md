# 知行AI — 人生管理规划助手

> 一个通过深度对话帮你理清目标、制定策略、追踪执行的 AI 助手。
> 端侧推理，隐私零上传。

---

## 一、产品定位

从"帮你反思过去"到"帮你规划未来"。

核心体验闭环：**表达诉求 → 理解意图 → 目标拆解 → 策略生成 → 执行追踪 → 主动提醒**。

每次对话结束后，LLM 提取对话中涉及的**目标、策略、约束**，汇入全局面板（Dashboard）。面板自动合并、去重、跨对话关联，形成用户的全局态势图。

| 传统 AI Chatbot | 助手 AI |
|:--|:--|
| 你问它答，给你答案 | 它理解你，帮你拆解问题 |
| 聊完就忘 | 每次对话汇入全局视图，目标/策略持续追踪 |
| 数据上云 | 对话全程端侧推理，隐私零上传 |

---

## 二、完整闭环

```
┌─────────────────────────────────────────────────────────────────┐
│ 环节 1: 对话 (ConversationStrategy + ModelGateway.converse)        │
│                                                                  │
│  注入已有目标列表 → 模式 C 工作：                                  │
│    1. 先追问理解用户需求                                          │
│    2. 给出解法/推荐路径（目标 + 策略）                             │
│    3. 检测重叠 → 建议合并而非新增目标                              │
│                                                                  │
│  例："你说的这个其实跟你已有的'攒钱'目标很像，要不要合并？"          │
└─────────────────────────────┬───────────────────────────────────┘
                              │ 结束对话
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ 环节 2: 提取 + 确认 (Extractor → StrategyBriefPage)               │
│                                                                  │
│  Extractor 输出：                                                 │
│    - new_goals (proposed，不直接 active)                          │
│    - goal_updates (仅建议，不自动改状态)                           │
│    - strategies (附属于目标)                                      │
│    - cross_patterns (洞察)                                       │
│                                                                  │
│  StrategyBriefPage 三区：                                         │
│    🎯 新目标        — [确认]/[忽略]，点击即生效无弹窗               │
│    🔄 已有目标变更   — [确认]/[忽略]，点击→二级页查看策略            │
│    💡 洞察          — [删除]                                      │
│                                                                  │
│  未操作条目 → 保留 proposed，Dashboard 仍可见                       │
│  策略查看 → 点击目标行箭头跳二级页                                  │
└─────────────────────────────┬───────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ 环节 3: Dashboard (三区)                                          │
│                                                                  │
│  🎯 目标与策略 — GoalCard（分类色条 + 内含策略 + 进度条）           │
│  📋 执行路线   — StrategyTimeline（活跃目标未完成策略按优先级排序）  │
│  💡 洞察       — CrossPatternCard（浅金底格）                     │
│                                                                  │
│  状态流转规则：见 §四 交互规则                                     │
│  级联规则：    见 §四 交互规则                                     │
└─────────────────────────────┬───────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ 环节 4: 推送与提醒（服务端）                                       │
│                                                                  │
│  Dashboard 数据变更 → 端侧同步到服务端                             │
│    ├── 用户未开「AI 优化推送」→ 规则模式：deadline 到期前推送       │
│    └── 用户开启「AI 优化推送」→ LLM 模式：DeepSeek 分析上下文推送   │
│                                                                  │
│  推送通道：WebSocket 站内横幅（服务端触发，不走系统推送）          │
│  隐私保护：不传对话原文，仅传结构化摘要，服务端不持久化用户数据       │
│                                                                  │
│  详见 §十二 服务端推送方案                                         │
└─────────────────────────────────────────────────────────────────┘
```

---

## 三、核心功能与概念模型

Dashboard 基于 OKR 框架组织三层信息：

| 层 | OKR 对应 | 业务含义 | 生成方式 |
|:--|:--:|------|------|
| 🎯 目标 | O (Objective) | 用户想要达成什么 | AI 在对话中提议 → 用户确认后才定为目标 |
| 📋 策略 | KR (Key Results) | 如何支撑目标达成 | AI 为每个确认的目标推导可执行步骤 |
| 💡 洞察 | — | 从多对话中发现的自我认知 | AI 观察跨对话的行为模式、性格矛盾、价值观倾向 |

**目标 vs 洞察的核心区别**：目标是面向未来的行动方向（"我要去哪"），洞察是面向自我的认知发现（"我原来是这样"）。

Dashboard 三区对应：

| 分区 | 内容 | 视角 |
|------|------|------|
| 目标与策略 | GoalCard（目标 + 内含策略 + 进度条） | 按目标查看 |
| 执行路线 | StrategyTimeline（所有待办策略按优先级排序） | 按时间/优先级查看 |
| 洞察 | CrossPatternCard（跨对话自我认知） | 按认知查看 |

| 功能 | 说明 |
|------|------|
| 🎯 助手对话 | AI 主动分析、拆解、建议，目标需用户确认而非隐式生成 |
| 📊 目标与策略 | GoalCard 展示目标 + 策略 + 进度条，按目标维度组织 |
| 📋 执行路线 | 所有目标的待办策略合并，按优先级+时间排序的时间线 |
| 💡 洞察 | LLM 观察跨对话模式：性格矛盾、行为倾向、价值观归纳 |
| 🔗 目标合并 | 同名目标自动合并（视为同一目标的补充），跨对话关联 |
| 🧠 端侧推理 | llama.cpp + Qwen3.5-2B，全程离线，隐私零上传 |
| 📂 历史记录 | 对话历史持久化 + 收藏 + 左滑删除 |

---

## 四、交互规则

### 确认方式

| 场景 | 确认方式 | 理由 |
|------|:--:|------|
| Brief 页 新目标确认 | 点击即生效 | 对话刚结束，内容热乎，非意外操作 |
| Brief 页 状态变更确认 | 点击即生效 | 同上 |
| Brief 页 未操作条目 | 保留 proposed | 不丢弃用户数据 |
| Dashboard 目标状态切换 | 弹窗二次确认 | 单独操作，可能误触 |
| Dashboard 策略勾选 | 弹窗二次确认 | 关键操作 |
| 洞察删除 | 直接删除 | 非关键操作 |

### 级联规则

- Goal → paused：下属未完成策略从执行路线隐藏，不删除记录
- Goal → completed：下属策略全部标记为 completed
- Goal → active（恢复）：策略重新出现在执行路线
- Strategy → completed：从执行路线移除

### 状态流转

```
Goal:
  proposed ──Brief确认──→ active ──Dashboard弹窗──→ completed
                                     └──Dashboard弹窗──→ paused

Strategy:
  pending ──Dashboard弹窗──→ completed
```

**核心原则：任何状态变更的唯一入口是用户操作，AI 不可自动修改已有目标/策略的状态。**

---

## 五、架构

```
┌──────────────────────────────────────────────────────┐
│                  Flutter UI (Dart)                    │
│                                                      │
│  DashboardPage  ChatPage  StrategyBriefPage          │
│  HistoryPage    ModelManagePage                     │
│                                                      │
│  ┌──────────────────────────────────────────────┐   │
│  │  Provider 层 (Chat/Dashboard/StrategyBrief)  │   │
│  └──────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────┐   │
│  │  Engine 层（纯逻辑）                          │   │
│  │  ConversationStrategy  StrategistExtractor    │   │
│  └──────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────┐   │
│  │  Llm 服务层 (core/llm，唯一实例)              │   │
│  │  Llm 接口 ── LlmService（单一模式来源）       │   │
│  │  转换段: ContextPolicy（双端对等）            │   │
│  │  生成段: LocalGeneration  CloudGeneration     │   │
│  └──────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────┐   │
│  │  Repository 层 (Conversation/Dashboard)       │   │
│  └──────────────────────────────────────────────┘   │
│                                                      │
│         llama.cpp (Dart FFI) + Metal（可选，默认 CPU）│
│              Qwen3.5-2B (Q4_K_M)                     │
└──────────────────────────┬───────────────────────────┘
                           │ POST /api/sync
                           ▼
┌──────────────────────────────────────────────────────┐
│              Node.js 服务端 (server/)                 │
│                                                      │
│  Express API → 规则引擎 / LLM 引擎 → 推送决策         │
│                                                      │
│  ┌──────────────┐  ┌────────────────────────────┐   │
│  │ Rules Engine │  │ DeepSeek Chat API          │   │
│  │ (node-cron)  │  │ (LLM 模式，用户可选开启)     │   │
│  └──────────────┘  └────────────────────────────┘   │
│                         ↓                            │
│              WebSocket → 客户端站内横幅             │
└──────────────────────────────────────────────────────┘
```

### 分层规则

```
pages/widgets  → providers / models / core
providers      → engine / repository / models / core(仅 ModelGateway)
engine         → models / core(仅 ModelGateway)
repository     → models / core
```

**业务对 LLM 的依赖面 = `ModelGateway` 门面**（`core/model_gateway.dart`，v2，2026-09-14）：业务只见「塞上下文 → 调执行 → 拿输出」，**不感知**当前后端是本地还是云端。门面双面：**对话面**（有状态，私有持有 `ContextState`，编排装配 → 生成 → 溢出自愈，压缩策略业务零感知）+ **补全面**（`ask / askJson / stop / readiness` 一行透传 `Llm`，另有 `truncateForAsk` 做单次补全的输入截断；输入预算守门 fail-fast 由 llm 基建在补全唯一通道施加，透传自动获得）。`Llm`（`core/llm/llm.dart`）降为**基建接缝接口，业务永久不 import**；模式经 `LlmService.mode` 注入门面（单一模式解析点不变）；后端（本地 llama.cpp / 云端 BYOK）差异全部关进 `core/llm`。生命周期（加载/释放/模式切换防抖）仍归 `LlmService`，业务既不构造也不释放后端资源。

目录准入（按**文件性质**分桶，避免「能跑就行」式摆放）：

| 目录 | 准入标准 | 反例 |
|---|---|---|
| `widgets/` | 只放 Widget 组件（`StatelessWidget` / `StatefulWidget`） | 纯函数、mixin、常量 |
| `engine/` | 纯逻辑（无 UI / IO 依赖）；**widgets 不得依赖 engine** | 直接碰 `BuildContext` 的东西 |
| `providers/` | 状态与编排（`ChangeNotifier`） | 无状态纯函数 |
| `utils/` | 非 Widget 的辅助件（非引擎逻辑、非状态、非组件） | 可归类到上面三桶的东西 |
| `prompt/` | 提示词构造（业务人设；**基建不认识业务**，故人设留业务侧） | 装配/压缩逻辑（归 `core/llm`） |

---

## 六、目录结构

```
lib/
├── main.dart
├── app.dart
├── core/
│   ├── constants.dart                  # 全局常量（端侧模型参数 local* / 云端预算 cloud* / 服务端地址）
│   ├── logger.dart                     # 统一日志
│   ├── model_gateway.dart              # 业务唯一门面（对话面编排 + 补全面透传；含公开 AskSummarizer）
│   ├── context/                        # 上下文管理域（纯语义，零 llm 依赖）
│   │   ├── context_state.dart          # 压缩状态（摘要 / 游标 k / 记账；实例由门面私有持有）
│   │   ├── context_assembly.dart       # 装配骨架：过滤 → 度量 → 装窗 → 挤出（无状态，双端共用）
│   │   ├── context_budget.dart         # 预算常量（localInputBudget / cloudInputBudget）+ 装箱原语
│   │   ├── local_context_policy.dart   # 端侧参数档案（token 度量；estimator 注入）
│   │   ├── cloud_context_policy.dart   # 云端参数档案（字符度量）
│   │   └── summary_prompt.dart         # 摘要提示词（模型能力差异，App 级覆盖点）
│   ├── llm/                            # 大模型服务域（后端差异全关在这里；业务不 import）
│   │   ├── llm.dart                    # 基建接缝接口（ask/askJson/readiness/stop）+ ChatMode/LlmPhase/LlmReadiness
│   │   ├── llm_service.dart            # 唯一实现：单一模式解析点 + mode 模式源 + activeModelPath 模型源注入 + 生命周期（延迟释放防抖）+ 生成工厂 deliveryFor
│   │   ├── generation/                 # 多轮流式生成段（唯一形状差异所在）
│   │   │   ├── generation.dart             # ChatGeneration 接口 + LlmContextOverflowException
│   │   │   ├── local_generation.dart       # 端侧生成（无状态重放，唯一 llama SDK 依赖点）
│   │   │   ├── cloud_generation.dart       # 云端 BYOK 生成（SSE；prime 空实现保契约对称）
│   │   │   ├── tail_dedup.dart             # 尾部 LCS 去重（TailDeduplicator，有状态）
│   │   │   ├── think_stream_filter.dart    # 流式 think 剥离（三阶段状态机）
│   │   │   └── sse_parser.dart             # SSE 半包/畸形 JSON 容错
│   │   ├── single_shot/                # 单次一问一答
│   │   │   ├── input_guard.dart            # ask 输入预算守门（fail-fast，补全唯一通道单点施加）
│   │   │   ├── cloud_request.dart          # 云端单次补全（BYOK 端点复用）
│   │   │   ├── local_inference.dart        # 端侧单次补全原语（装箱/事件循环）
│   │   │   └── think_tag_stripper.dart     # <think> 标签剥离
│   │   └── engine/                     # 端侧引擎底座
│   │       ├── llama_service.dart          # 端侧引擎生命周期/池化（模型路径由调用方提供）
│   │       ├── token_estimator.dart        # token 估算纯函数（装配度量与单发守门共用口径）
│   │       ├── active_model_manager.dart   # 活跃模型状态（非单例；ChangeNotifier + activeModelPath 源）
│   │       └── llama_template_estimator.dart # 端侧 token 度量（llama 模板知识，注入 context 域）
│   ├── data/                           # 数据域
│   │   ├── conversation_service.dart   # 会话缓存编排（Identity Map）
│   │   ├── models/                     # chat_models/conversation/dashboard_models/available_model
│   │   └── repository/                 # conversation/dashboard/settings 仓库 (sqflite/prefs)
│   ├── platform/                       # 平台基建
│   │   ├── push_service.dart           # 设备标识 token（FCM，未配 Firebase 则 mock；进程级单例）
│   │   ├── push_socket_service.dart    # WS 站内推送连接（进程级单例）
│   │   └── sync_service.dart           # 服务端数据同步（非单例；组合根构造，业务经 Provider 树取）
│   └── ui/                             # 跨 feature UI 基建
│       ├── theme.dart
│       ├── route_observer.dart
│       └── in_app_banner.dart          # 站内推送横幅
│
├── features/
│   ├── chat/
│   │   ├── prompt/                       # 业务人设（基建不认识业务，人设留业务侧）
│   │   │   └── conversation_strategy.dart  # 系统提示词(含goals) + LCS 去重
│   │   ├── providers/chat_provider.dart  # 两件事：持消息列表 + 每轮传人设；无模式分支、不持压缩状态（v2 收进门面）
│   │   ├── widgets/chat_bubble.dart, chat_input.dart,
│   │   │        markdown_message_view.dart    # 只放 Widget 组件
│   │   ├── utils/                        # 非 Widget 的辅助件（准入：非引擎逻辑、非状态、非 Widget）
│   │   │   ├── markdown_blocks.dart      # fence 感知流式块切分（纯函数，零 import）
│   │   │   └── snackbar_throttle.dart    # SnackBar 按文本防抖
│   │   └── chat_page.dart
│   │
│   ├── dashboard/
│   │   ├── providers/dashboard_provider.dart
│   │   ├── widgets/
│   │   │   ├── goal_card.dart
│   │   │   ├── dashboard_header.dart
│   │   │   ├── strategy_timeline.dart
│   │   │   └── cross_pattern_card.dart
│   │   ├── dashboard_page.dart
│   │   └── goal_detail_page.dart      # 目标二级页（策略明细）
│   │
│   ├── strategy_brief/
│   │   ├── engine/
│   │   │   ├── strategist_extractor.dart
│   │   │   └── chat_utils.dart
│   │   ├── models/extraction_result.dart
│   │   ├── providers/strategy_brief_provider.dart
│   │   ├── strategy_brief_page.dart
│   │   └── strategy_detail_page.dart
│   │
│   ├── history/
│   │   ├── providers/history_provider.dart
│   │   ├── widgets/conversation_card.dart
│   │   └── history_page.dart
│   │
│   ├── settings/
│   │   ├── providers/settings_provider.dart  # 偏好开关透传
│   │   └── settings_page.dart          # 偏好设置（云端 BYOK / GPU 加速等）
│   │
│   └── model_manager/
│       ├── engine/model_download_service.dart
│       ├── providers/model_download_provider.dart
│       └── model_manage_page.dart

server/                                # 服务端（独立于 Flutter 工程）
├── src/
│   ├── index.js                       # Express 入口 + cron
│   ├── routes/sync.js                 # POST /api/sync
│   └── services/
│       ├── push.js                    # 推送决策分发
│       ├── rules-engine.js            # 规则模式
│       ├── llm-engine.js              # DeepSeek LLM 模式
│       └── wsHub.js                   # token → socket 登记与下发
├── tests/                             # push / wsHub 单元测试
├── package.json
└── .env.example
```

---

## 七、数据模型

### 对话 (conversations 表)

| 字段 | 类型 | 说明 |
|------|------|------|
| id | INTEGER PK | 自增 |
| topic | TEXT | 话题 |
| status | TEXT | active / completed |
| is_favorite | INTEGER | 0/1 |
| messages_json | TEXT | List\<ChatMessage\> JSON |
| extraction_json | TEXT | 提取结果缓存 JSON（可为 null） |
| insight_json | TEXT | v1 遗留列，当前未使用 |
| graph_json | TEXT | v1 遗留列，当前未使用 |
| created_at | TEXT | ISO 8601 |
| updated_at | TEXT | 最后活跃时间 |

### 目标 (goals 表)

| 字段 | 类型 | 说明 |
|------|------|------|
| id | INTEGER PK | 自增 |
| title | TEXT | 目标标题 |
| category | TEXT | career/finance/relationship/health/growth/other |
| status | TEXT | proposed/active/completed/paused |
| priority | INTEGER | 1-5 |
| source_conv_ids | TEXT | 来源对话 ID JSON 数组 |
| deadline | TEXT | 截止日期，可为 null |
| notes | TEXT | 备注 |
| created_at | TEXT | ISO 8601 |
| updated_at | TEXT | ISO 8601 |

### 策略 (strategies 表)

| 字段 | 类型 | 说明 |
|------|------|------|
| id | INTEGER PK | 自增 |
| goal_id | INTEGER FK | 关联目标 |
| description | TEXT | 策略描述 |
| type | TEXT | selfAction/aiAssist/externalDep |
| next_step | TEXT | 下一步动作 |
| completed | INTEGER | 0/1 |
| next_reminder | TEXT | 提醒时间（服务端阶段启用） |
| created_at | TEXT | ISO 8601 |

### 跨对话模式 (cross_patterns 表)

| 字段 | 类型 | 说明 |
|------|------|------|
| id | INTEGER PK | 自增 |
| label | TEXT | 模式名称 |
| description | TEXT | 详细描述 |
| source_conv_ids | TEXT | 来源对话 ID JSON 数组 |
| frequency | INTEGER | 出现次数 |
| detected_at | TEXT | ISO 8601 |

---

## 八、数据流

### 对话结束流程

```
ChatPage._endConversation（chat_page.dart）
  │
  └── 1) Navigator.pushReplacement → StrategyBriefPage(conversation)
         （此处不落库、不提取，仅传递会话对象）

StrategyBriefPage → StrategyBriefProvider（进入页面即触发）
  │
  ├── 2) 读 conversations.extraction_json 缓存：命中则直接渲染，跳过提取
  │
  ├── 3) 未命中 → StrategistExtractor(_gateway).extract(conversation, existingGoals)
  │      ├── 对话 < 2 条用户消息 → 跳过（null）
  │      ├── LLM 判断 relevant? → false → 跳过（null）
  │      └── 提取 → ExtractionResult
  │           ├── new_goals: status=proposed（不直接 active）
  │           ├── goal_updates: 仅建议，不自动改 DB
  │           ├── strategies: 附属于目标
  │           └── cross_patterns: 洞察（同 label 则 frequency+1）
  │
  ├── 4) _saveExtractionAndComplete：
  │      写 extraction_json → ConversationService.finishConversation()
  │      （标记 status = 'completed'）
  │
  └── 5) 用户逐条确认/忽略（点击即生效，无弹窗）
         ├── 确认 → proposed → active
         ├── 忽略 → 丢弃
         └── 未操作 → 保留 proposed
```

### 全局面板加载

```
DashboardPage.initState()
  └── DashboardProvider.load()
        ├── goals (from DB)
        ├── strategies (from DB, grouped by goal)
        └── crossPatterns (from DB)
```

### 推送同步数据流

```
DashboardProvider 数据变更时（目标新增/策略完成/状态变更）：
  └── SyncService.syncToServer()
        ├── 读取当前所有 active goal + 对应 strategies
        ├── 读取当前「AI 优化推送」开关状态
        ├── 构造请求体（无对话原文、无语义向量）：
        │     device_token: "xxx"
        │     mode: "rules" | "llm"
        │     goals: [{ title, category, status, deadline, priority }]
        │     strategies: [{ description, goal_id, completed }]
        └── POST /api/sync

服务端：
  └── 收到 data → node-cron 定时扫描
        ├── 规则模式 → deadline 在3天内且未完成 → WS 站内推送
        └── LLM 模式 → DeepSeek 按 goals + strategies 文本摘要决策
              ├── should_push=true → 生成个性化推送内容 → WS 站内推送
              └── should_push=false → 跳过

推送到达 App：
  └── PushSocketService（WS）收到 {type:push} → 顶部 Overlay 站内横幅（InAppBanner）
```

---

## 九、技术栈

| 层 | 技术 | 用途 |
|------|------|------|
| UI | Flutter 3.x | 跨平台 iOS + Android |
| 状态管理 | Provider (ChangeNotifier) | 全局状态 |
| 推理引擎 | llama.cpp (C++) | 端侧 LLM |
| Dart 桥接 | llama_cpp_dart (Dart FFI) | Dart → C++ |
| 模型 | Qwen3.5-2B Instruct (Q4_K_M) | 中文对话 + 目标提取 |
| GPU 加速 | Metal（llama.cpp `n_gpu_layers`，设置页开关，**默认关 = 纯 CPU**） | 开启后全量卸载到 GPU；macOS M1 实测 46–71 tok/s（端侧 Qwen3.5-2B Q4_K_M，原始实测记录未随仓库分发） |
| 本地存储 | sqflite | 对话 + 目标/策略持久化 |
| 模型下载 | dio (HTTP Range) | HuggingFace 断点续传 |
| 模型托管 | HuggingFace | GGUF 分发 |
| 服务端 | Node.js + Express | 推送决策、定时任务 |
| 推送通道 | 服务端触发 + WebSocket 站内横幅 | App 在线即可达，不依赖系统推送通道 |
| 服务端 LLM | DeepSeek Chat API | 推送内容智能生成（用户可选） |

### 构建与环境要点

**iOS（Flutter 3.44）**

- 走 **SPM**，不写 Podfile（手写会被 Flutter 标记 non-standard）。Xcode 签名 Team 需设置；`GoogleService-Info.plist` 缺失不崩（`initializeApp` 已 try/catch）。
- `llama_cpp_dart` 是纯 Dart FFI 插件（无 `flutter: plugin:` 段）→ 不进 SPM/CocoaPods 自动集成；`ios/Runner/llama.xcframework` 手动 vendored，纯 SPM 下必须手动在 pbxproj 里**链接 + 嵌入**进 Runner。
- **两道坎**：① 忘写 `PBXBuildFile section` 定义 → 悬空引用被 Xcode 静默忽略（既不链接也不嵌入，App 能启动但 `spawnFromProcess` 报 symbol not found；Embed 那条需带 `settings={ATTRIBUTES=(CodeSignOnCopy,)}`）；② PBXFileReference 挂 `Runner` 组时 path 写 `llama.xcframework`，**不能**写 `Runner/llama.xcframework`。判别：能启动但 symbol not found = 没链接；报 `RuntimeRoot/Users/...` = 运行时 dlopen 路径错。改完必查产物（`Runner.app/Frameworks/` 有 llama + `otool -L ... | grep llama`），不能只看 UUID/括号。
- **正确机制**：`LlamaEngine.spawnFromProcess()` —— 框架由 dyld 在 App 启动期加载，`@rpath` 由 App 的 `LD_RUNPATH_SEARCH_PATHS`（`@executable_path/Frameworks`，Flutter 默认有）解析；框架自身故意不带 `LC_RPATH`。**不要**改用运行时 `spawn(libraryPath:)` dlopen，也不要给框架补 rpath 构建阶段。

**本地测试**

- 跑测试前**必须清代理环境变量**：宿主若注入 `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY`，flutter_tester 连本机回环也走代理，**加载阶段**即全量报 `WebSocketException: Invalid WebSocket upgrade request`（非沙箱问题、与断言无关）：
  `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u ALL_PROXY -u all_proxy NO_PROXY='*' no_proxy='*' flutter test`
- 验收基线：`flutter analyze` 0 issue + 全量测试绿。

**macOS Sandbox 调试**

- errno：`1`→权限（查 entitlement）、`2`→文件不存在、`13`→文件系统权限。
- entitlement 对应：`files.absolute-path.read-only`（读项目外模型）/ `network.client`（出站）/ `network.server`（入站）。
- 注意：`curl` 能通 ≠ App 内能通。

---

## 十、设计决策

| 问题 | 决策 |
|------|------|
| 主页 | DashboardPage 唯一主页 |
| 新对话入口 | Dashboard [+] → ChatPage |
| 对话模式 | 助手模式（ConversationStrategy），模式 C：先追问 → 给解法 → 检测重叠 |
| Prompter 上下文 | 注入已有目标列表，助手可基于已有目标追问 |
| 对话结束 | ChatPage → StrategyBriefPage（用户确认）→ Dashboard |
| 目标生成 | AI 提议（proposed）→ 用户确认 → active；不可隐式生成 |
| 目标去重 | 对话时人设注入已有目标列表 → 助手检测重叠并**建议**合并（提示词行为，非代码自动合并）；提取回写阶段 `matchGoal` 按 goalId 优先、title 回退映射到已有目标（`strategy_brief_provider.dart`），不新建重复项；`sourceConvIds` 目前仅用于展示「来自 N 次对话」 |
| 生成层 | `ChatGeneration` 接口双实现（`core/llm/generation/`）：`LocalGeneration`（无状态重放——每轮 `clear()` + 按装配结果全量重放；唯一 llama SDK 依赖点兼测试接缝 `ChatSession` 抽象）/ `CloudGeneration`（BYOK 直连 OpenAI 兼容端点 SSE；`prime` 空实现保契约对称）；**两者同构：都无会话状态**；生成只抛类型化信号（`LlmContextOverflowException`），自愈编排在门面 |
| 上下文管理 | `ContextPolicy` 抽象（`core/context/context_assembly.dart`，**无状态** + `ContextState` 外置状态：摘要/游标 k/防御位，**实例由门面私有持有**；窗口 = `eligible.sublist(k)` 每轮现算）：`LocalContextPolicy`（token 度量 + 溢出硬收缩 4 条；estimator 由门面注入）/ `CloudContextPolicy`（字符数近似 + 无收缩）；摘要器统一为门面内公开的 `AskSummarizer`（提示词在 `core/context/summary_prompt.dart`，传输走 `Llm.ask`）；过滤/装窗/溢出契约为共享同一段代码（`BaseContextPolicy`） |
| 端侧 KV 复用 | **暂不采纳**（登记为后续候选）：包便捷层 `EngineChat` 每轮 `session.clear()` + 全量 re-prefill，跨轮复用不存在；能力可由公开的 `EngineSession`/`LlamaSession` 自管获得，但受「前缀须逐 token 一致 / KV 缓存独占（seqId）/ 缓存持续累积」三条硬约束，且**压缩事件本身即缓存失效点**。结论、证据与 spike 方案见 `docs/notes/2026-09-11/local-kv-reuse-feasibility.md` |
| 端侧消息列表真相源 | **已采纳：无状态重放**（2026-09-11 实施，2026-09-12 迁至生成层）。唯一真相源 = `ChatProvider._messages`；`ChatSession` 不再持有权威副本——每轮 `generate()` 恒为 `clear()` → `addSystem(人设)` → `[addSystem(摘要卡)]` → 按装配结果**全量重放** → `generate()`（`core/llm/generation/local_generation.dart` 的 `_syncSession`）。全生命周期只有 **1 个** `ChatSession` 实例。**不变量**：①引擎内消息列表 ≡ 人设 + 摘要卡 + 装配结果（逐字）；②assistant 条目均为 strip 后正文；③生成层不持消息列表；④不得再引入依赖「引擎状态与我方索引对齐」的机制。行为变更：模型不再看到自身历史 think（与云端对齐）；token 预算估算变准 → `context full` 显著减少。依据见 `docs/notes/2026-09-11/local-kv-reuse-feasibility.md` §10–§11 |
| 大模型服务分层 | **v2 已实施**（2026-09-14，T1–T7 全部落地：T6 文档同步、T7 目录重组与改名；偏差②已收口为 `truncateForAsk`，2026-09-15；v1 见 `docs/plans/2026-09-12-llm-service-layering-{design,plan}.md`）。**业务唯一门面 = `ModelGateway`**（`core/model_gateway.dart`）：对话面有状态（私有持 `ContextState`，编排装配 → 生成 → 溢出自愈；摘要统一走 `llm.ask`；模式切换 `resetWindow` 保摘要清游标）+ 补全面（`ask/askJson/stop/readiness` 一行透传，另有 `truncateForAsk` 做单次输入截断；预算守门 fail-fast，超限抛 `GatewayInputOverflowException`，不截断不自愈）。`Llm` 降为基建接缝（业务禁止 import），`LlmService` 收敛为：单一模式解析点 + `mode` 模式源注入 + `activeModelPath` 模型源注入（模型路径不再走全局常量）+ 生命周期（延迟释放防抖）+ 生成工厂 `deliveryFor`（池化与 BYOK 指纹重建）。守门落在补全唯一通道（`LlmService.ask`），askJson 经透传自动覆盖。设计见 `docs/plans/2026-09-14-model-gateway-facade-{design,plan}.md` |
| 实例唯一性 | **组合根统一装配**（`main()`）：需要被替换 / 驱动 UI / 持有需释放资源的实例走 Provider 或构造注入（`ModelGateway` / `ActiveModelManager` / `SyncService`），进程级唯一且无释放需求的基础设施保留 `static final instance`（`SettingsRepository` / `PushService` / `PushSocketService` / `LlamaService`）。保留单例者也**不直连 `.instance`**——依赖走构造注入（如 `SyncService(pushService:, settings:)`、`LlmService(settings:, activeModelPath:)`），唯一性来自「组合根只造一次」而非 static 字段；`ActiveModelManager` 为非单例 `ChangeNotifier`，其 `activeModelPath`（`ValueListenable<String?>`）注入 `LlmService`，取代原全局可变常量 `AppConstants.defaultModelPath` |
| 云端模型 | BYOK：用户在设置页自带 baseUrl/key/模型名，端侧直连，服务端不参与对话；三项未配齐则云端开关不可开（降级 Mock） |
| 云端摘要 | 复用同一 BYOK 端点，非流式小请求（max_tokens 512）；预算极大（60k 字符）故实践中基本不触发，机制作超长对话兜底 |
| 状态变更 | 仅用户操作触发，AI 不可自动修改已有目标/策略状态 |
| Brief 页确认 | 点击即生效，无弹窗（区别于 Dashboard 的弹窗确认） |
| 提取频率 | 每次对话结束都提取 |
| 洞察定义 | 跨对话自我认知：性格矛盾、行为模式、价值观，面向自我而非行动 |
| 策略查看 | Brief 页点击目标箭头 → 二级页查看策略明细 |
| 提醒 | 端侧不自行决策推送；服务端 cron 触发，经 WebSocket 下发，客户端顶部站内横幅展示 |
| 推送模式 | 两级控制：默认规则模式（deadline 到期前 N 天），可选开启 LLM 优化模式（服务端 DeepSeek 按 goals/strategies 决策）；两者上报字段相同，仅 `mode` 值不同 |
| 推送隐私 | 不传对话原文，仅传结构化摘要；服务端不持久化用户数据 |
| 服务端模型 | DeepSeek Chat API（成本低、中文优化好），MVP 用 API 验证链路 |

---

## 十一、历史版本

| 版本 | 日期 | 内容 |
|------|------|------|
| v1 (MVP) | 2026-07-01 ~ 07-13 | 苏格拉底教练：问答题 → AI 追问 → 洞察总结 → 思维图谱 |
| v2 (当前) | 2026-07-16 | 助手模式：Dashboard 主页 → 对话 → 目标提取 → 全局态势 |
| v2.1 | 2026-07-20 | 服务端推送方案：推送与提醒闭环，端云协同推理 |
| v2.2 | 2026-09-12 | 大模型服务分层：业务只调 `Llm` 接口，后端差异关进 `core/llm`（三层·四段·三关节）；`features/chat/engine/` 解体；生命周期收口（窄通知源 + 延迟释放防抖 + 就绪态上接口） |
| v2.3 | 2026-09-14 | ModelGateway 门面重构：业务唯一门面改为 `ModelGateway`（对话面持状态编排 / 补全面透传 + 预算守门），`Llm` 降为基建接缝、`ContextState` 收进门面，ask 输入超预算 fail-fast |
| v2.4 | 2026-09-15 | 目录重组与命名收口：`core/context` 独立成域（零 llm 依赖）、`core/llm` 分 `generation`/`single_shot`/`engine` 三桶（delivery→generation、completion→single_shot、ChatDelivery→ChatGeneration）；单次补全截断收口门面 `truncateForAsk`，业务对两域内件零直连 |
| v2.5 | 2026-09-15 | 全局状态与单例收口：`ActiveModelManager` 去单例（组合根构造 + Provider 树，暴露 `activeModelPath` 源）；删全局可变常量 `AppConstants.defaultModelPath`；`LlamaService.ensureReady/release` 的模型路径改必传；token 估算抽为纯函数 `engine/token_estimator.dart`；`SyncService` 去单例并删死代码 `static enabled`；`PushService` 统一为 `static final instance` 写法 |

**仓库内文档**：`docs/PROJECT.md`（本文件，活文档）+ `docs/plans/`（按日期归档的设计与计划）+ `docs/notes/2026-09-11/`（端侧 KV 复用技术评估）。

**未分发内容**：早期 MVP 文档（`demo-plan-socratic-ai.md` / `requirements-goals.md`）、day1–day9 脚手架计划、7 月逐日学习/工作日志均已移出仓库（本地保留，见 `.gitignore`）。

---

## 十二、服务端推送方案

> 设计依据：本文档 §二 环节 4
> 实现：`docs/plans/2026-08-05-in-app-push-design.md` + `docs/plans/2026-08-05-in-app-push-plan.md`
> （2026-08-05 决策：推送触达改为「服务端触发 + WebSocket + 客户端站内横幅」，替代旧 FCM/APNs 系统推送路线）

### 为什么需要服务端推送

知行AI 的核心闭环缺少"主动触达"——用户设了目标但容易忘。端侧无法实现真正的推送（App 被杀死后失效），必须由服务端主动触达；v2.1 采用 WebSocket 站内横幅（App 在线即可达，不依赖系统推送通道）。

### 两级推送模式

设置页只有一个开关：「AI 优化推送」

| 开关状态 | 上报数据 | 服务端决策 | 推送效果 |
|:--|:--|:--|:--|
| OFF（默认） | `mode="rules"` + goals（title/分类/状态/deadline/priority）+ strategies（描述/goal_id/完成态） | 规则匹配（到期前N天） | 模板化："「XX目标」3天后到期" |
| ON | **与 OFF 完全相同的字段**，仅 `mode="llm"`（不额外上传数据，不存在语义向量） | DeepSeek 按 goals/strategies 文本摘要决策 | 个性化："上次提到想约 mentor 喝咖啡——这周还剩两天" |

### 隐私设计

- 默认 OFF：`mode=rules`，服务端不调用 LLM
- 开启时弹窗说明数据范围（首次开启的同意弹窗，`aiPushConsented` 为持久位）
- 两级模式上报字段完全相同，只有 `mode` 值不同（不存在语义向量）
- **永远不传对话原文**——端侧提取后再上传结构化结果
- **服务端不持久化用户数据**——收到 → 处理 → 丢弃

### 端云协同

```
端侧（Qwen3.5-2B）：对话理解 + 目标提取 → 隐私敏感的计算放在本地
服务端（DeepSeek）：推送决策 + 内容生成 → 需要更强推理的任务放在云端
```

### 面试叙事

这个方案可以从四个角度展开：
1. **产品闭环**："设定了目标但缺乏主动触达 → 加上推送完成了 设定→追踪→提醒 的闭环"
2. **隐私设计**："两级控制 + 不传原文 + 服务端不持久化——移动端隐私合规意识"
3. **端云协同**："端侧负责隐私计算，服务端做推理增强——不是非此即彼"
4. **技术选型**："DeepSeek 比 GPT-4 成本低、中文好，MVP 阶段性价比最优"
