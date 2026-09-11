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
│  │  Engine 层                                    │   │
│  │  ConversationStrategy  StrategistExtractor    │   │
│  │  ContextPolicy（双端对等）              │   │
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
│              WebSocket → 客户端站内横幅             │
└──────────────────────────────────────────────────────┘
```

### 分层规则

```
pages/widgets  → providers / models / core
providers      → engine / repository / models / core
engine         → models / core
repository     → models / core
```

目录准入（按**文件性质**分桶，避免「能跑就行」式摆放）：

| 目录 | 准入标准 | 反例 |
|---|---|---|
| `widgets/` | 只放 Widget 组件（`StatelessWidget` / `StatefulWidget`） | 纯函数、mixin、常量 |
| `engine/` | 纯逻辑（无 UI / IO 依赖）；**widgets 不得依赖 engine** | 直接碰 `BuildContext` 的东西 |
| `providers/` | 状态与编排（`ChangeNotifier`） | 无状态纯函数 |
| `utils/` | 非 Widget 的辅助件（非引擎逻辑、非状态、非组件） | 可归类到上面三桶的东西 |

---

## 六、目录结构

```
lib/
├── main.dart
├── app.dart
├── core/
│   ├── constants.dart                  # 全局常量（端侧模型参数 local* / 服务端地址）
│   ├── logger.dart                     # 统一日志
│   ├── llm/                            # 端侧 LLM 推理域
│   │   ├── llama_service.dart          # 引擎生命周期/池化/token 估算
│   │   ├── active_model_manager.dart   # 活跃模型状态单例（ChangeNotifier）
│   │   └── think_tag_stripper.dart     # <think> 标签剥离
│   ├── data/                           # 数据域
│   │   ├── conversation_service.dart   # 会话缓存编排（Identity Map）
│   │   ├── models/                     # chat_models/conversation/dashboard_models/available_model
│   │   └── repository/                 # conversation/dashboard/settings 仓库 (sqflite/prefs)
│   ├── platform/                       # 平台基建
│   │   ├── push_service.dart           # 设备标识 token（FCM，未配 Firebase 则 mock）
│   │   ├── push_socket_service.dart    # WS 站内推送连接
│   │   └── sync_service.dart           # 服务端数据同步
│   └── ui/                             # 跨 feature UI 基建
│       ├── theme.dart
│       ├── route_observer.dart
│       └── in_app_banner.dart          # 站内推送横幅
│
├── features/
│   ├── chat/
│   │   ├── engine/                       # 对话引擎（按职责分二级子目录）
│   │   │   ├── client/                   # 传输：接口 + 双实现 + SSE 帧解析
│   │   │   │   ├── chat_client.dart          # abstract ChatClient 接口
│   │   │   │   ├── local_chat_client.dart    # 本地 llama 传输（无状态重放：clear + 全量重放装配结果）
│   │   │   │   ├── cloud_chat_client.dart    # 云端直连 BYOK（OpenAI 兼容 /chat/completions SSE；装配交策略）
│   │   │   │   └── sse_parser.dart           # SSE 半包/畸形 JSON 容错
│   │   │   ├── context/                  # 上下文管理：抽象 + 共享算法 + 双端策略
│   │   │   │   ├── context_policy.dart       # 上下文管理抽象（过滤/度量/装窗/压缩）+ 共享装配骨架
│   │   │   │   ├── local_context_policy.dart # 端侧策略自足单元（度量+摘要+装配）
│   │   │   │   └── cloud_context_policy.dart # 云端策略自足单元（度量+摘要+装配，与端侧逐位对称）
│   │   │   └── prompt/                   # 双端共享提示词
│   │   │       └── conversation_strategy.dart # 系统提示词(含goals) + LCS 去重
│   │   ├── providers/chat_provider.dart  # 单 ChatClient，无模式分支
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
│   ├── settings/
│   │   └── settings_page.dart          # 偏好设置（云端模式/GPU 加速等）
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
        ├── 规则模式 → deadline 在3天内且未完成 → WS 站内推送
        └── LLM 模式 → DeepSeek 分析上下文
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
| iOS 加速 | CoreML / Metal | GPU 推理 (46-71 tok/s) |
| Android 加速 | NNAPI | NPU 推理 |
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
| 目标去重 | 相同 title 自动合并 sourceConvIds；ConversationStrategy 检测重叠建议合并 |
| 传输层 | ChatClient 接口双实现：LocalChatClient（无状态重放——每轮 `clear()` + 按装配结果全量重放）/ CloudChatClient（BYOK 直连 OpenAI 兼容端点 SSE）；**两者同构：都无会话状态**；Provider 单 client 无模式分支 |
| 上下文管理 | ContextPolicy 抽象（过滤/度量/装窗/压缩/溢出契约），双端各一份薄装配：LocalContextPolicy（token 度量 + 端侧摘要器 + 溢出硬收缩 4 条）/ CloudContextPolicy（字符数近似 + 云端摘要器 + 无收缩）；①③⑤为共享同一段代码 |
| 端侧 KV 复用 | **暂不采纳**（登记为后续候选）：包便捷层 `EngineChat` 每轮 `session.clear()` + 全量 re-prefill，跨轮复用不存在；能力可由公开的 `EngineSession`/`LlamaSession` 自管获得，但受「前缀须逐 token 一致 / KV 缓存独占（seqId）/ 缓存持续累积」三条硬约束，且**压缩事件本身即缓存失效点**。结论、证据与 spike 方案见 `docs/notes/2026-09-11/local-kv-reuse-feasibility.md` |
| 端侧消息列表真相源 | **已采纳：无状态重放**（2026-09-11 实施）。唯一真相源 = `ChatProvider._messages`；`EngineChat` 不再持有权威副本——每轮 `generateResponse` 恒为 `ChatSession.clear()` → `addSystem(人设)` → `[addSystem(摘要卡)]` → 按装配结果**全量重放** → `generate()`（`local_chat_client.dart` 的 `_syncSession`）。全生命周期只有 **1 个** `ChatSession` 实例。**已删除**的复杂度：`_consumed` diff 游标、`_skipNextHistoryAi` 位置型补丁、`evicted` 双分支（`AssembledContext.evicted` 字段一并移除）、`_rebuildSession` 的 `dispose + createSession`。**新增**：`ChatSession.clear()`；顶层纯函数 `eventsToText`（补上被丢弃的 `DoneEvent.trailingText`）。**不变量**：①引擎内消息列表 ≡ 人设 + 摘要卡 + 装配结果（逐字）；②assistant 条目均为 strip 后正文；③client 不持消息列表；④不得再引入依赖「引擎状态与我方索引对齐」的机制。行为变更：模型不再看到自身历史 think（与云端对齐）；token 预算估算变准（不再有隐形 think 占用）→ `context full` 显著减少。依据与代价核算见 `docs/notes/2026-09-11/local-kv-reuse-feasibility.md` §10–§11，设计与计划见 `docs/plans/2026-09-11-local-stateless-replay-{design,plan}.md` |
| 云端模型 | BYOK：用户在设置页自带 baseUrl/key/模型名，端侧直连，服务端不参与对话；三项未配齐则云端开关不可开（降级 Mock） |
| 云端摘要 | 复用同一 BYOK 端点，非流式小请求（max_tokens 512）；预算极大（60k 字符）故实践中基本不触发，机制作超长对话兜底 |
| 状态变更 | 仅用户操作触发，AI 不可自动修改已有目标/策略状态 |
| Brief 页确认 | 点击即生效，无弹窗（区别于 Dashboard 的弹窗确认） |
| 提取频率 | 每次对话结束都提取 |
| 洞察定义 | 跨对话自我认知：性格矛盾、行为模式、价值观，面向自我而非行动 |
| 策略查看 | Brief 页点击目标箭头 → 二级页查看策略明细 |
| 提醒 | 端侧不自行决策推送；服务端 cron 触发，经 WebSocket 下发，客户端顶部站内横幅展示 |
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

> 设计依据：本文档 §二 环节 4
> 实现：`docs/plans/2026-08-05-in-app-push-design.md` + `docs/plans/2026-08-05-in-app-push-plan.md`
> （2026-08-05 决策：推送触达改为「服务端触发 + WebSocket + 客户端站内横幅」，替代旧 FCM/APNs 系统推送路线）

### 为什么需要服务端推送

知行AI 的核心闭环缺少"主动触达"——用户设了目标但容易忘。端侧无法实现真正的推送（App 被杀死后失效），必须由服务端主动触达；v2.1 采用 WebSocket 站内横幅（App 在线即可达，不依赖系统推送通道）。

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
