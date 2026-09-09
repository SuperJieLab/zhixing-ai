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
│ 环节 1: 对话 (ConversationStrategy + ChatClient)                 │
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
│  推送通道：Firebase Cloud Messaging（APNs + FCM 统一）            │
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
│  │  Engine 层                                    │   │
│  │  ConversationStrategy  StrategistExtractor    │   │
│  │  LocalChatClient  CloudChatClient             │   │
│  │  ConversationService  LlamaService            │   │
│  └──────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────┐   │
│  │  Repository 层 (Conversation/Dashboard)       │   │
│  └──────────────────────────────────────────────┘   │
│                                                      │
│         llama.cpp (Dart FFI) + Metal/CoreML          │
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
│              APNs / FCM → 用户设备                    │
└──────────────────────────────────────────────────────┘
```

### 分层规则

```
pages/widgets  → providers / models / core
providers      → engine / repository / models / core
engine         → models / core
repository     → models / core
```

---

## 六、目录结构

```
lib/
├── main.dart
├── app.dart
├── core/
│   ├── engine/
│   │   ├── llama_service.dart
│   │   └── conversation_service.dart
│   ├── models/
│   │   ├── chat_models.dart
│   │   ├── conversation.dart
│   │   ├── dashboard_models.dart
│   │   └── available_model.dart
│   ├── repository/
│   │   ├── conversation_repository.dart
│   │   └── dashboard_repository.dart
│   ├── theme.dart
│   ├── constants.dart
│   └── logger.dart
│
├── features/
│   ├── chat/
│   │   ├── engine/
│   │   │   ├── chat_client.dart          # abstract ChatClient 接口
│   │   │   ├── conversation_strategy.dart # 系统提示词(含goals) + LCS 去重
│   │   │   ├── local_chat_client.dart    # 本地 llama 传输（diff 增量 append）
│   │   │   ├── cloud_chat_client.dart    # 云端 SSE 传输（窗口构造）
│   │   │   ├── sse_parser.dart           # SSE 半包/畸形 JSON 容错
│   │   │   └── markdown_blocks.dart      # fence 感知流式块切分
│   │   ├── providers/chat_provider.dart  # 单 ChatClient，无模式分支
│   │   ├── widgets/chat_bubble.dart, chat_input.dart,
│   │   │        markdown_message_view.dart
│   │   ├── snackbar_throttle.dart
│   │   └── chat_page.dart
│   │
│   ├── dashboard/
│   │   ├── providers/dashboard_provider.dart
│   │   ├── widgets/
│   │   │   ├── goal_card.dart
│   │   │   ├── dashboard_header.dart
│   │   │   ├── strategy_timeline.dart
│   │   │   └── cross_pattern_card.dart
│   │   └── dashboard_page.dart
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
│   └── model_manager/
│       ├── engine/model_download_service.dart
│       ├── providers/model_download_provider.dart
│       └── model_manage_page.dart
│
└── services/
    └── sync_service.dart              # 服务端数据同步

server/                                # 服务端（独立于 Flutter 工程）
├── src/
│   ├── index.js                       # Express 入口 + cron
│   ├── routes/sync.js                 # POST /api/sync
│   └── services/
│       ├── push.js                    # 推送决策分发
│       ├── rules-engine.js            # 规则模式
│       └── llm-engine.js              # DeepSeek LLM 模式
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
ChatPage._endConversation
  │
  ├── 1) ConversationService.finishConversation()
  │      标记 status = 'completed'
  │
  ├── 2) StrategistExtractor.extract(conversation, existingGoals)
  │      ├── 对话 < 2 条用户消息 → 跳过（null）
  │      ├── LLM 判断 relevant? → false → 跳过（null）
  │      └── 提取 → ExtractionResult
  │           ├── new_goals: status=proposed（不直接 active）
  │           ├── goal_updates: 仅建议，不自动改 DB
  │           ├── strategies: 附属于目标
  │           └── cross_patterns: 洞察
  │
  ├── 3) Navigator.pushReplacement → StrategyBriefPage(result)
  │      ├── 用户逐条确认/忽略（点击即生效，无弹窗）
  │      └── DashboardProvider 根据用户操作写入 DB
  │           ├── 确认 → proposed → active
  │           ├── 忽略 → 丢弃
  │           └── 未操作 → 保留 proposed
  │
  └── 4) 返回 Dashboard
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
        ├── 构造请求体：
        │     mode: "rules" | "llm"
        │     goals: [{ title, category, status, deadline, priority }]
        │     strategies: [{ description, goal_id, completed }]
        │     vectors: [...] | null  ← 仅 mode=llm 时有值
        └── POST /api/sync

服务端：
  └── 收到 data → node-cron 定时扫描
        ├── 规则模式 → deadline 在3天内且未完成 → APNs/FCM 推送
        └── LLM 模式 → DeepSeek 分析上下文
              ├── should_push=true → 生成个性化推送内容 → APNs/FCM
              └── should_push=false → 跳过

推送到达 App：
  └── onMessage / onNotificationOpened
        ├── 策略提醒 → 跳转对应 GoalDetailPage
        └── 目标到期 → 跳转 DashboardPage
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
| iOS 加速 | CoreML / Metal | GPU 推理 (46-71 tok/s) |
| Android 加速 | NNAPI | NPU 推理 |
| 本地存储 | sqflite | 对话 + 目标/策略持久化 |
| 模型下载 | dio (HTTP Range) | HuggingFace 断点续传 |
| 模型托管 | HuggingFace | GGUF 分发 |
| 服务端 | Node.js + Express | 推送决策、定时任务 |
| 推送通道 | Firebase Cloud Messaging | iOS APNs + Android FCM 统一 |
| 服务端 LLM | DeepSeek Chat API | 推送内容智能生成（用户可选） |

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
| 目标去重 | 相同 title 自动合并 sourceConvIds；ConversationStrategy 检测重叠建议合并 |
| 传输层 | ChatClient 接口双实现：LocalChatClient（llama diff 增量）/ CloudChatClient（SSE 窗口）；Provider 单 client 无模式分支 |
| 状态变更 | 仅用户操作触发，AI 不可自动修改已有目标/策略状态 |
| Brief 页确认 | 点击即生效，无弹窗（区别于 Dashboard 的弹窗确认） |
| 提取频率 | 每次对话结束都提取 |
| 洞察定义 | 跨对话自我认知：性格矛盾、行为模式、价值观，面向自我而非行动 |
| 策略查看 | Brief 页点击目标箭头 → 二级页查看策略明细 |
| 提醒 | 端侧不自行发推送（App 被杀死后失效），推送通过服务端 APNs/FCM 通道实现 |
| 推送模式 | 两级控制：默认规则模式（title+deadline），可选开启 LLM 优化模式（DeepSeek 分析上下文） |
| 推送隐私 | 不传对话原文，仅传结构化摘要；服务端不持久化用户数据 |
| 服务端模型 | DeepSeek Chat API（成本低、中文优化好），MVP 用 API 验证链路 |

---

## 十一、历史版本

| 版本 | 日期 | 内容 |
|------|------|------|
| v1 (MVP) | 2026-07-01 ~ 07-13 | 苏格拉底教练：问答题 → AI 追问 → 洞察总结 → 思维图谱 |
| v2 (当前) | 2026-07-16 | 助手模式：Dashboard 主页 → 对话 → 目标提取 → 全局态势 |
| v2.1 | 2026-07-20 | 服务端推送方案：推送与提醒闭环，端云协同推理 |

**旧 MVP 文档归档**：`docs/demo-plan-socratic-ai.md` 和 `docs/requirements-goals.md` 已移入 `docs/archived/`。

---

## 十二、服务端推送方案

> 设计依据：本文档 §二 环节 4 + §十二 服务端推送方案
> 实现计划：`docs/plans/2026-07-20-server-push-plan.md`

### 为什么需要服务端推送

知行AI 的核心闭环缺少"主动触达"——用户设了目标但容易忘。端侧无法实现真正的推送（App 被杀死后失效），必须通过服务端 APNs/FCM 通道。

### 两级推送模式

设置页只有一个开关：「AI 优化推送」

| 开关状态 | 上报数据 | 服务端决策 | 推送效果 |
|:--|:--|:--|:--|
| OFF（默认） | title + deadline + priority | 规则匹配（到期前N天） | 模板化："「XX目标」3天后到期" |
| ON | 上述 + 语义向量（对话摘要脱敏） | DeepSeek 分析上下文 | 个性化："上次提到想约 mentor 喝咖啡——这周还剩两天" |

### 隐私设计

- 默认 OFF，不上传语义向量
- 开启时弹窗说明数据范围
- **永远不传对话原文**——端侧提取后再上传结构化结果
- **服务端不持久化用户数据**——收到 → 处理 → 丢弃

### 端云协同

```
端侧（Qwen2.5-2B）：对话理解 + 目标提取 → 隐私敏感的计算放在本地
服务端（DeepSeek）：推送决策 + 内容生成 → 需要更强推理的任务放在云端
```

### 面试叙事

这个方案可以从四个角度展开：
1. **产品闭环**："设定了目标但缺乏主动触达 → 加上推送完成了 设定→追踪→提醒 的闭环"
2. **隐私设计**："两级控制 + 不传原文 + 服务端不持久化——移动端隐私合规意识"
3. **端云协同**："端侧负责隐私计算，服务端做推理增强——不是非此即彼"
4. **技术选型**："DeepSeek 比 GPT-4 成本低、中文好，MVP 阶段性价比最优"
