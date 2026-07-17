# 军师 AI — 人生管理规划助手

> 一个通过深度对话帮你理清目标、制定策略、追踪执行的 AI 助手。
> 端侧推理，隐私零上传。

---

## 一、产品定位

从"帮你反思过去"到"帮你规划未来"。

核心体验闭环：**表达诉求 → 理解意图 → 目标拆解 → 策略生成 → 执行追踪 → 主动提醒**。

每次对话结束后，LLM 提取对话中涉及的**目标、策略、约束**，汇入全局面板（Dashboard）。面板自动合并、去重、跨对话关联，形成用户的全局态势图。

| 传统 AI Chatbot | 军师 AI |
|:--|:--|
| 你问它答，给你答案 | 它理解你，帮你拆解问题 |
| 聊完就忘 | 每次对话汇入全局视图，目标/策略持续追踪 |
| 数据上云 | 对话全程端侧推理，隐私零上传 |

---

## 二、完整闭环

```
┌─────────────────────────────────────────────────────────────────┐
│ 环节 1: 对话 (StrategistPrompter)                                │
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
| 🎯 军师对话 | AI 主动分析、拆解、建议，目标需用户确认而非隐式生成 |
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
│  │  StrategistPrompter  StrategistExtractor      │   │
│  │  ConversationService  LlamaService            │   │
│  └──────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────┐   │
│  │  Repository 层 (Conversation/Dashboard)       │   │
│  └──────────────────────────────────────────────┘   │
│                                                      │
│         llama.cpp (Dart FFI) + Metal/CoreML          │
│              Qwen3.5-2B (Q4_K_M)                     │
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
│   ├── model_manager.dart               # 模型下载/就绪检测（全局 Provider）
│   ├── engine/
│   │   ├── llama_service.dart            # LLM 引擎缓存池
│   │   └── conversation_service.dart     # 对话生命周期管理
│   ├── models/
│   │   ├── chat_models.dart              # ChatMessage / ChatTurn
│   │   ├── conversation.dart             # Conversation + 序列化
│   │   ├── dashboard_models.dart         # Goal / Strategy / CrossPattern
│   │   └── available_model.dart          # 可下载模型描述
│   ├── repository/
│   │   ├── conversation_repository.dart  # 对话 CRUD (sqflite)
│   │   └── dashboard_repository.dart     # 目标/策略 CRUD
│   ├── theme.dart
│   ├── constants.dart
│   └── logger.dart
│
├── features/
│   ├── chat/                             # 军师模式对话
│   │   ├── engine/
│   │   │   └── strategist_prompter.dart   # 军师 Prompt
│   │   ├── providers/chat_provider.dart
│   │   ├── widgets/chat_bubble.dart, chat_input.dart
│   │   ├── snackbar_throttle.dart          # SnackBar 防抖
│   │   └── chat_page.dart
│   │
│   ├── dashboard/                        # 全局面板
│   │   ├── providers/dashboard_provider.dart
│   │   ├── widgets/
│   │   │   ├── goal_card.dart
│   │   │   ├── dashboard_header.dart
│   │   │   ├── strategy_timeline.dart
│   │   │   └── cross_pattern_card.dart
│   │   └── dashboard_page.dart
│   │
│   ├── strategy_brief/                   # 对话结束大局影响页
│   │   ├── engine/
│   │   │   ├── strategist_extractor.dart  # LLM 提取目标/策略
│   │   │   └── chat_utils.dart            # 对话文本格式化
│   │   ├── models/
│   │   │   └── extraction_result.dart     # ExtractionResult / GoalUpdate
│   │   ├── providers/strategy_brief_provider.dart
│   │   ├── strategy_brief_page.dart
│   │   └── strategy_detail_page.dart
│   │
│   ├── history/                          # 历史列表
│   │   ├── providers/history_provider.dart
│   │   ├── widgets/conversation_card.dart
│   │   └── history_page.dart
│   │
│   └── model_manager/                    # 模型下载 UI
│       ├── engine/model_download_service.dart
│       ├── providers/model_download_provider.dart
│       └── model_manage_page.dart
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

---

## 十、设计决策

| 问题 | 决策 |
|------|------|
| 主页 | DashboardPage 唯一主页 |
| 新对话入口 | Dashboard [+] → ChatPage |
| 对话模式 | 军师模式（StrategistPrompter），模式 C：先追问 → 给解法 → 检测重叠 |
| Prompter 上下文 | 注入已有目标列表，军师可基于已有目标追问 |
| 对话结束 | ChatPage → StrategyBriefPage（用户确认）→ Dashboard |
| 目标生成 | AI 提议（proposed）→ 用户确认 → active；不可隐式生成 |
| 目标去重 | 相同 title 自动合并 sourceConvIds；Prompter 检测重叠建议合并 |
| 状态变更 | 仅用户操作触发，AI 不可自动修改已有目标/策略状态 |
| Brief 页确认 | 点击即生效，无弹窗（区别于 Dashboard 的弹窗确认） |
| 提取频率 | 每次对话结束都提取 |
| 洞察定义 | 跨对话自我认知：性格矛盾、行为模式、价值观，面向自我而非行动 |
| 策略查看 | Brief 页点击目标箭头 → 二级页查看策略明细 |
| 提醒 | 服务端就绪前用 flutter_local_notifications |

---

## 十一、历史版本

| 版本 | 日期 | 内容 |
|------|------|------|
| v1 (MVP) | 2026-07-01 ~ 07-13 | 苏格拉底教练：问答题 → AI 追问 → 洞察总结 → 思维图谱 |
| v2 (当前) | 2026-07-16 | 军师模式：Dashboard 主页 → 对话 → 目标提取 → 全局态势 |

**旧 MVP 文档归档**：`docs/demo-plan-socratic-ai.md` 和 `docs/requirements-goals.md` 已移入 `docs/archived/`。
