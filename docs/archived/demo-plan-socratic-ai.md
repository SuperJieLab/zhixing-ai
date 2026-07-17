# 苏格拉底式 AI 对话 — MVP 执行方案（已归档）

> ⚠️ 本文档已归档。项目已切换为军师/谋士模式，当前定义见 `docs/PROJECT.md`。
>
> 最后更新：2026-07-13
> 当前进度：MVP Day 1-9 全部完成。新方向：军师/谋士模式 Plans A/B/C 已完成（2026-07-16）

---

## 一、产品定义

### 一句话描述

一个通过苏格拉底式追问，帮用户理清思路、发现自我认知盲区的 AI 对话 App。

### 核心差异化

| 传统 AI Chatbot | 本产品 |
|:--|:--|
| 用户问 → AI 答 | AI 问 → 用户想 |
| 「给我答案」 | 「帮我想清楚」 |
| 越用越依赖 | 越用越有独立思考能力 |
| 数据上云 | 对话在端侧，只有脱敏图谱上后端 |

### 核心场景

- 职业困惑：「该转管理还是深耕技术？」
- 两难决策：「要不要接这个 Offer？」
- 自我探索：「我为什么总在 deadline 前焦虑？」

### MVP 功能边界

| 功能 | MVP | 后续 |
|------|:--:|:--:|
| 话题选择（5 个预设 + 自定义） | ✅ | |
| AI 驱动多轮追问对话 | ✅ | |
| 对话结束 + 洞察总结 | ✅ | |
| 聊天界面（AI 提问，用户回答） | ✅ | |
| 对话历史列表 | ✅ | |
| 后端 — 对话存储 + 多端同步 | ✅ | |
| 端侧 — 思维图谱生成 + 交互可视化 | ✅ | |
| 话题推荐（基于历史） | | v1.1 |
| 语音输入 | | v1.1 |
| Watch 端触发 + 心率感知 | | v1.2 |
| Web 端回顾台 | | v1.2 |

---

## 二、核心体验设计

### 一次完整对话流程

```
┌─────────────────────────────────────────────────┐
│  1. 选话题                                       │
│  ┌──────────────────────────────────────────┐  │
│  │ 🧭 职业发展    💭 两难决策                │  │
│  │ 🧠 自我探索    💼 工作难题                │  │
│  │ ❤️ 人际关系    ✍️ 自定义...               │  │
│  └──────────────────────────────────────────┘  │
│                    ↓                            │
│  2. AI 开场                                     │
│  ┌──────────────────────────────────────────┐  │
│  │ AI：你提到想聊聊职业方向——如果三年后的你  │  │
│  │ 回头看今天做的选择，你觉得他会在意什么？   │  │
│  └──────────────────────────────────────────┘  │
│                    ↓                            │
│  3. 用户回答                                    │
│  ┌──────────────────────────────────────────┐  │
│  │ 我：他会更在意我有没有勇敢尝试...          │  │
│  └──────────────────────────────────────────┘  │
│                    ↓                            │
│  4. AI 追问（重复 5-8 轮）                      │
│  ┌──────────────────────────────────────────┐  │
│  │ AI：你说到「勇敢尝试」——它对你来说意味着   │  │
│  │ 什么？是离开舒适区，还是承担失败的风险？   │  │
│  └──────────────────────────────────────────┘  │
│                    ↓                            │
│  5. AI 洞察总结                                 │
│  ┌──────────────────────────────────────────┐  │
│  │ 🌟 这次对话中你发现的：                    │  │
│  │ • 你重视「不后悔」胜过「不失败」           │  │
│  │ • 你害怕的不是能力不够，是选择错误          │  │
│  │ • 你已经知道答案了，只是需要一个理由        │  │
│  └──────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

### 对话深度感知

AI 会在内部追踪对话深度 state，决定何时追问、何时总结：

```
浅层（1-3 轮）→ 探索性问题，帮用户展开话题
中层（4-6 轮）→ 挑战性问题，追问底层假设
深层（7-8 轮）→ 引导总结，产出洞察
```

---

## 三、架构总览

```
┌──────────────────────────────────────────┐
│        Flutter UI 层 (Dart)              │
│  ┌─────────┐  ┌────────┐  ┌─────────┐  │
│  │ 话题选择  │  │ 对话界面 │  │ 思维图谱 │  │
│  │ TopicSelector│ ChatView │  │ MindMap │  │
│  └─────────┘  └────────┘  └─────────┘  │
│       │            │            │        │
│       │    dart_llama (Dart FFI)  │       │
│       │         ↓    │            │       │
│       │   llama.cpp (C++)  │            │
│       │    iOS: CoreML backend          │
│       │    Android: NNAPI backend       │
│       │                                 │
│       └─────── API Client ──────────────│
│                    ↓                     │
├──────────────────────────────────────────┤
│           Backend (Go) — 规划中          │
│  ┌──────────┐                            │
│  │ REST API  │                            │
│  │ - 对话CRUD│                            │
│  │ - 用户同步│                            │
│  └──────────┘                            │
│         │                                │
│    PostgreSQL / SQLite                   │
└──────────────────────────────────────────┘
```
> 注：Day 6 实现后，图谱生成和渲染完全在端侧完成（LLM 生成 JSON → Dart 布局 → CustomPainter 渲染），无需后端参与。

### 关键设计决策

| 决策 | 选择 | 理由 |
|------|------|------|
| 推理框架 | llama.cpp | 跨平台 C++ 引擎，iOS/Android 统一编译 |
| 模型 | Qwen3.5-2B (Q4_K_M) | 中文训练数据远超 Gemma，追问质量更好；~1.06GB |
| 桥接方案 | Dart FFI | 零 Native 开发，双端共享推理代码 |
| 后端语言 | Go | 轻量、高并发、部署简单（单二进制） |
| 后端数据库 | PostgreSQL (生产) / SQLite (MVP) | 开始用 SQLite 零运维，后续切 PG |
| Native 加速 | llama.cpp 内置 backend | iOS 自动 CoreML，Android 自动 NNAPI |

---

## 四、推理管线

### 苏格拉底 Prompt 模板

系统提示词（固定文本，在对话开始时设置一次）：

```
你是一位苏格拉底式对话教练。你不会给建议或答案，你只通过提问帮用户自己找到答案。

**重要：直接输出追问问题，不要输出思考过程、不要输出推理步骤。**

## 对话规则
1. 每次只输出一个问题，不要附带任何解释
2. 问题必须基于用户刚才的回答深入挖掘
3. 如果用户回答比较浅，追问具体化：「你说的XX具体是指什么？」
4. 如果用户提出了一个判断，追问假设：「是什么让你这样认为？」
5. 如果发现用户前后矛盾，温和指出：「你之前说XX，现在说YY，这之间的变化是因为什么？」
6. 当对话达到足够深度（用户展现出新的自我认知），输出 [SUMMARY] 标记并给出洞察总结

用户消息中带有"追问方向"标记，你只需要基于该方向追问一个问题。
问题控制在 150 字以内，用中文。
不要给建议，不要一次问多个问题。
不要重复之前问过的内容。
```

**架构说明**：不再使用占位符拼接完整 Prompt。改为：
- 系统提示词固定不变，由 llama.cpp chat template 管理
- 每轮 Dart 层在用户消息前注入「追问方向」标记（如 `追问方向：【探索】`）
- llama.cpp 的 chat template 自动管理对话历史（system/user/assistant 角色）

### 追问策略（Dart 层辅助逻辑）

通过 `_ProbeStage` 枚举实现梯度追问，在 `SocraticPrompter` 中根据轮次和回答长度决定追问方向：

```dart
enum _ProbeStage { exploration, deepening, challenge, summary }

// 每阶段对应的追问方向标记（注入用户消息）
exploration → 追问方向：【探索】帮用户展开这个话题，问一个开放性问题
deepening    → 追问方向：【深入】追问具体细节或例子
challenge    → 追问方向：【挑战】挑战底层假设，比如"换个角度呢"
summary      → 追问方向：【总结】引导回顾对话，问"最大的收获是什么"

// 阶段切换逻辑
轮次 1      → exploration（探索）
轮次 2-3    → deepening（深入）
轮次 4-6    → challenge（挑战）
轮次 7+     → summary（引导总结）

// 短回答优先升级
用户回答 < 20 字 → 自动升级到 deepening（无论当前轮次）
```

追问策略不替代 AI，而是给 Prompt 提供一个「建议追问方向」，由模型决定具体怎么问。

**去重机制**：Dart 层维护最近 3 轮追问文本，最长公共子串相似度 > 60% 时触发重试。

### 推理参数

| 参数 | 值 | 原因 |
|------|-----|------|
| Context 窗口 | 4096 tokens | 端侧推理，保留完整对话历史 |
| Temperature | 0.5 | 追问需要一定变化，但不能太随机 |
| Max output | 128 tokens | 一次只问一个问题，不需要长输出 |
| Top-p | 0.85 | 保证追问多样性同时不失控 |
| Repeat penalty | 1.15 | 防止模型重复问类似问题 |

### 洞察总结 Prompt（对话结束时调用）

```
你是一位思维教练。请分析以下对话，提取用户的核心洞察。

对话内容：
{full_conversation}

输出 JSON：
{
  "core_insights": ["洞察1", "洞察2", "洞察3"],
  "underlying_values": ["价值观1", "价值观2"],
  "contradictions_found": ["矛盾1"],
  "next_topic_suggestion": "建议的下一个话题"
}
```

---

## 五、Flutter UI 设计

### 页面结构

```
话题选择页 → 对话页 → 洞察总结页
   ↓                        ↓
 历史列表页 ←──────────── 思维图谱页
```

### 页面 1：话题选择页

- 顶部：App 标题 + 副标题「帮你想清楚」
- 中部：5 个话题卡片（图标 + 标题 + 一句话描述）
  - 🧭 职业发展 — 「该深耕还是该转型？」
  - 💭 两难决策 — 「两个选项，怎么选？」
  - 🧠 自我探索 — 「我想成为什么样的人？」
  - 💼 工作难题 — 「这个问题到底卡在哪？」
  - ❤️ 人际关系 — 「这段关系我该怎么看？」
- 底部：✍️ 自定义话题输入框
- 历史对话入口（右上角图标）

### 页面 2：对话页

- 传统的聊天气泡布局，但方向感是「AI 在左（提问方），用户在右（回答方）」
- AI 气泡：简洁问题，可带 emoji 引导情绪
- 用户气泡：你的回答
- 底部：文本输入框 + 发送按钮
- 顶部栏：当前话题 + 对话轮次计数器
- AI 思考中的 loading 动画：「正在思考下一个问题...」（约 2-4s）
- 用户回答后，AI 气泡逐行出现（打字机效果，但其实是下一个问题生成中）
- 当用户不想继续时：右上角「结束对话」按钮 → 触发洞察总结

### 页面 3：洞察总结页

- 顶部：🎉 对话完成动画
- 核心洞察列表（卡片式，每条一个卡片）
- 底层价值观标签（#勇气 #自由 #安全感）
- 发现的矛盾（如果有）
- 「查看思维图谱」按钮
- 「开始新对话」按钮

### 页面 4：思维图谱页

- 从后端拉取的对话图谱可视化
- 节点：话题 → 关键回答 → 洞察
- 连线：对话推进逻辑
- 可缩放、平移的交互式图谱
- Flutter 实现：CustomPainter + GestureDetector

### 页面 5：历史列表页

**数据来源**：本地 sqflite（Day 5a），后续 Day 6 增加后端同步。

- 对话卡片列表（话题 + 轮次数 + 相对时间 + 洞察摘要）
- 右侧收藏星标（点击切换，数据持久化）
- 左滑删除（确认弹窗）
- 点击卡片 → 跳转 InsightsPage（回看洞察总结）
- 空状态：「还没有对话记录，开始第一次探索吧」
- 顶部统计：共 N 条对话

**存储模型**：
```
Conversation (sqflite)
  id, topic, status(active/completed), is_favorite
  messages_json (List<ChatMessage> JSON)
  insight_json (InsightResult JSON, nullable)
  graph_json (ConversationGraph JSON, nullable)  ← Day 6 DB v2 迁移
  created_at, updated_at
```

**保存时机**：
| 时机 | 操作 |
|:--|------|
| 进入 ChatPage | INSERT 新记录 |
| 每轮 AI 追问完成 | UPDATE messages_json |
| 结束对话 | UPDATE insight_json + status='completed' |

**组件结构**：
```
lib/features/history/
├── engine/conversation_repository.dart    # sqflite CRUD
├── providers/conversation_provider.dart   # 列表状态管理
├── widgets/conversation_card.dart         # 卡片组件
└── history_page.dart                      # 列表页
```

### 状态矩阵

| 状态 | UI 表现 |
|------|------|
| 模型加载中 | 启动页全屏进度条「正在准备 AI 思考引擎(~1.06GB)」 |
| 模型加载失败 | 红色错误页 + 重试按钮 |
| 等待用户输入 | 输入框可用，光标闪烁 |
| AI 思考中 | 输入框禁用，三点跳动动画 |
| 对话正常 | 气泡正常展示 |
| 网络不可用 | 顶上黄色提示条「离线模式：数据暂存本地」（不影响推理） |
| 洞察生成中 | 总结页 loading |
| JSON 解析失败 | 黄色提示 + 兜底纯文本展示 |

---

## 六、后端设计

### 为什么需要后端

- **多端同步**：手机聊完，换个设备能看到历史
- **思维图谱**：跨多轮对话提取关联，1B 小模型做不好，需要服务端推理（可调大模型 API 或本地规则引擎）
- **话题推荐**（后续）：基于聊天历史做个性化推荐
- **数据备份**：端侧数据不丢

### API 设计

```
POST   /api/v1/conversations         创建对话
GET    /api/v1/conversations         获取对话列表
GET    /api/v1/conversations/:id     获取单个对话详情
POST   /api/v1/conversations/:id/messages  追加消息
POST   /api/v1/conversations/:id/summary   触发洞察总结生成
GET    /api/v1/conversations/:id/graph     获取对话思维图谱
DELETE /api/v1/conversations/:id     删除对话

GET    /api/v1/insights              获取用户所有洞察
GET    /api/v1/mindmap               获取全局思维图谱
```

### 数据模型

```
Conversation:
  id, user_id, topic, status(active/completed), created_at, updated_at

Message:
  id, conversation_id, role(ai/user), content, round_number, created_at

Insight:
  id, conversation_id, content, type(core_insight/value/contradiction), created_at

MindNode:
  id, user_id, label, type(topic/insight/value), related_nodes: [id, ...]
```

### 技术选型

| 组件 | 选择 | 原因 |
|------|------|------|
| 语言 | Go | 编译快、单二进制部署、高并发天然优势 |
| 框架 | Gin | 轻量 HTTP 框架，社区成熟 |
| ORM | GORM | Go 最流行的 ORM |
| 数据库 MVP | SQLite (纯文件) | 零运维，开发机直接跑 |
| 数据库生产 | PostgreSQL | 图谱查询（JSONB 存节点关系） |
| 部署 | 阿里云/腾讯云 ECS | 最小实例即可（1C2G） |
| 图谱布局 | Dart 端侧辐射分布 | 计算节点坐标，客户端直接渲染 |

---

## 七、多设备联动（架构预留）

### 三层设备角色

| 设备 | 角色 | 数据流 |
|------|------|------|
| **Watch** | 触发器 + 传感器 | 每日推送问题 → 语音回答 → 心率数据 → 手机 |
| **Phone** | 主战场 | 完整对话 + 端侧推理 + 本地优先 |
| **Web/iPad** | 回顾台 | 历史对话 + 思维图谱 + 导出 |

### MVP 中的预留

- `HealthKitRepository` 抽象接口：定义了心率数据读取方法，MVP 返回 mock 数据
- Push Notification 基础设施：为后续 Watch 每日推送做准备
- 后端 API 版本化：`/api/v1/` 前缀，后续 Watch 独立 API 加 `/api/v2/watch/`
- Flutter 层 `DeviceCapability` 抽象：检测可用设备，动态调整 UI

简历话术：
> 设计了 Watch → Phone → Web 三层设备联动架构，通过 HealthKit 数据增强 AI 对话感知能力，为后续手表端深度集成预留了完善的技术接口。

---

## 八、实施计划（9 天核心版 + 高阶扩展）

### 核心版（App Store 上架）

| 天 | 阶段 | 内容 | 状态 |
|:--:|------|------|:--:|
| **1** | 工程搭建 | Flutter 项目 + 话题选择页 + 对话页 UI | ✅ |
| **2** | 端侧推理 | llama.cpp + Qwen3.5-2B + Metal 加速 | ✅ |
| **3** | 对话引擎 | 梯度追问策略 + Context 管理 + Token 追踪 | ✅ |
| **4** | 洞察总结 | InsightService + JSON 三层回退 + InsightsPage UI | ✅ |
| **5** | 端侧持久化 | sqflite 本地存储 + ConversationProvider + 历史列表 | ✅ |
| **6** | 思维图谱 | LLM 端侧生成图谱 JSON + CustomPainter 渲染 + 手势交互 | ✅ |
| **6a** | 架构重构 | LlamaService 缓存池 + 分层梳理 + MindMapService 内聚 | ✅ |
| **7** | 错误覆盖 | 状态矩阵全覆盖 + 边界 case + Android 验证 + 收藏 UI | ✅ |
| **8** | 模型下载 | HuggingFace 直链下载 + 断点续传 + 进度条 | ✅ |
| **9** | 收尾 | README + 录 Demo + 截图 + Push GitHub + 上架准备 | ✅ |

### 高阶版（Resume 加分项 — 后续迭代）

高阶功能分三个阶段，每个阶段都有独立的交付价值，且后一个阶段依赖前一个阶段。

#### 高阶 1：云端同步（后端 + 联调）

| 任务 | 内容 | 交付价值 |
|------|------|------|
| Go 后端 | Gin + SQLite + Conversation CRUD API | 数据有云端副本，不会丢 |
| 前后端联调 | Flutter dio 接后端 + 对话自动同步 | 本地优先，云端备份 |
| 冲突解决 | 时间戳排序 + 简单 last-write-wins | 多端写入不乱 |

**依赖**：无，可以独立开始。

#### 高阶 2：Web/iPad 回顾台

| 任务 | 内容 | 交付价值 |
|------|------|------|
| Web 端 | 拉取历史对话 + 思维图谱展示 + 导出 | 大屏上回顾深度对话 |
| iPad 适配 | 横屏双栏布局（列表 + 详情） | iPad 上更沉浸的回顾体验 |

**依赖**：高阶 1（需要后端提供数据）。Web 回顾台在数据到云端后就是纯前端项目。

#### 高阶 3：Watch 触发器 + 传感器

| 任务 | 内容 | 交付价值 |
|------|------|------|
| HealthKit 对接 | 心率数据接入对话上下文 | 生理数据增强 AI 感知 |
| Watch 语音回答 | WatchConnectivity 蓝牙通信 | 手表上快速回答 |
| 每日推送 | APNs/FCM 定时推问题 | 被动触发，降低使用门槛 |

**依赖**：
- 每日推送 → 高阶 1（后端推送服务器）
- Watch ↔ Phone 蓝牙 + HealthKit → **不依赖后端**（纯本地），可独立提前做

#### 依赖关系图

```
高阶 1：后端 + 云端同步
  ├── → 高阶 2：Web/iPad 回顾台
  └── → 高阶 3：Watch 推送部分
                Watch 传感器部分（独立，可提前做）
```

### 每日详细计划

**Day 1 — 工程搭建 ✅**
- Flutter 项目骨架 + Provider 状态管理
- 5 页 UI：话题选择 / 对话 / 洞察 stub / 历史 stub
- ChatBubble / ChatInput / TopicCard 组件
- 26 个测试通过

**Day 2 — 端侧推理接入 ✅**
- llama_cpp_dart 集成（替代原计划 dart_llama）
- Qwen3.5-2B Q4_K_M 模型加载，macOS Metal 加速 46-71 tok/s
- 对话引擎基础链路：Prompt 构建 → 流式输出 → Mock 回退

**Day 3 — 对话引擎 ✅**
- 梯度追问策略（_ProbeStage 枚举：探索→深入→挑战→总结）
- 短回答检测（< 20 字自动升级）
- Context Token 估算 + 监控（>1800 日志警告）
- 推理参数调优：temp 0.5 / topP 0.85 / maxTokens 128 / repeatPenalty 1.15
- 架构重构：DialogueEngine 接口 + SocraticPrompter 实现

**Day 4 — 洞察总结 ✅**
- InsightService：独立 EngineChat 分析全文，JSON 三层回退解析
- InsightsPage 完整 UI：洞察卡片 + 价值观标签 + 矛盾高亮 + stagger 入场动画
- ChatPage._endConversation 异步化（loading 弹窗 → LLM 分析 → 跳转）

**Day 5 — 端侧会话持久化 & 历史管理 ✅**

> 实现计划：`docs/plans/2026-07-06-day5a-local-persistence.md`
> 设计细节：见本文档第五节「页面 5：历史列表页」

- sqflite 本地数据库（单表 conversations，messages 和 insight 以 JSON 列存储）
- Conversation 数据模型（toMap/fromMap 序列化）
- ConversationRepository（CRUD 单例）
- ConversationProvider（ChangeNotifier 状态管理 + 活跃会话生命周期）
- ConversationCard（话题 + 轮次 + 洞察摘要 + 收藏星标 + 左滑删除）
- HistoryPage 重写（列表 + 空状态 + 点击查看洞察）
- ChatPage 集成：通过 ConversationProvider 管理会话生命周期

**Day 6 — 思维图谱 ✅**

> 端侧 LLM 生成图谱结构 + Flutter CustomPainter 渲染，无需后端。
> 实施总结：`docs/notes/2026-07-09/思维图谱-手势与布局修复.md`

### 已完成

- **GraphService**：LLM 将对话转为节点/边 JSON，紧凑格式 Prompt（`maxTokens=3072`，`contextSize=4096`）
- **图谱数据模型**：`GraphNode`（label, weight, type）+ `ConversationGraph`（nodes + edges + toJson/fromJson）
- **布局算法**：辐射分布 + 微力调整（替代纯力导向，解决多节点四角堆叠问题）
- **CustomPainter 渲染**（GraphPainter）：节点（大小按权重，36-56px）+ 连线（粗细按 strength）+ 颜色分类（topic/insight/value/action/contradiction）+ 类型标签
- **手势交互**（MindMapPage）：点击选中→弹窗详情 / 拖拽节点 / 双指缩放（以捏合点为锚点）/ 单指平移
- **图谱持久化**：DB v2 迁移（graph_json 列）+ Memory cache（MindMapService._graph）+ L1/L2 两层缓存
- **NodeDetailSheet**：底部弹窗展示节点详情（关联连线 + 上下游节点）

### 关键修复（Day 6 后续）

| 问题 | 根因 | 解决 |
|---|---|---|
| 节点飞出屏幕 | `CustomPaint(size: Size.infinite)` | `LayoutBuilder` 取实际尺寸 |
| 手势全部失效 | painter 未用 canvas 变换；hit test 坐标不统一 | 统一 `_canvasSize`；painter 加 `translate+scale` |
| 四角堆叠 | 斥力 600 倍于中心引力 + 硬 clamp | 辐射分布 + 微力（斥力降至 0.001/dist） |
| 缩放左上角锚点 | `canvas.scale()` 从原点缩放 | 以双指捏合点为锚点调整 offset |
| 平移震动 | `focalPointDelta` 是单帧增量 | `_offset += focalPointDelta` 累加 |
| 选中态文字消失 | 文字色 = 填充色 = 同一个 color | 选中文字改为白色 |
| 上下文溢出 | `contextSize=2048` | 扩大到 4096 |
| JSON 截断 | `maxTokens=1024` | 扩大到 3072 |

### 架构亮点

```
MindMapService（图谱生命周期）
  ├── 内部缓存 _graph（L1，同页复用）
  ├── DB 持久化（L2，跨会话复用）
  ├── GraphService（LLM 生成）
  └── 导航 MindMapPage（可视化）
       ├── ForceDirectedLayout（辐射分布 + 微力）
       ├── GraphPainter（CustomPaint + canvas 变换）
       └── 手势（GestureDetector + 坐标变换）
```

**Day 6a — 架构重构 ✅**

> LlamaService 缓存池重构 + MindMapService 内聚 + 分层梳理

- **LlamaService 重构**：从单例 loadModel 改为引擎缓存池（`Map<LlamaConfig, Future<LlamaEngine>>`）
  - 三层 API：`ensureReady()` / `ensureReadyWithModel(path)` / `ensureReadyWithConfig(config)`
  - 并发排队（池里存 Future），失败不缓存
  - Chat 操作各自面对 EngineChat，LlamaService 不封装
- **分层清理**：去掉 InsightsPage → LlamaService 直接引用；MindMapService 直接持有 ConversationRepository
- **回调消除**：saveGraph 逻辑从 ChatPage/HistoryPage 回调 → 内聚到 MindMapService（传 conversationId）
- **测试修复**：InsightService 不再无参构造（接收 LlamaEngine），测试改为纯 Dart（`package:test`）

### 代码量

| 层 | 文件 | 行数 |
|---|---|---|
| MindMap engine | graph_service / mindmap_service | ~200 |
| Layout | force_directed | ~100 |
| Painter | graph_painter | ~250 |
| Page + gestures | mindmap_page | ~200 |
| Detail sheet | node_detail_sheet | ~100 |
| Core model | chat_models (ConversationGraph) | ~50 |
| **小计** | | **~900 行新增** |

**Day 7 — 错误覆盖 + Android 验证 ✅**

- 实现所有状态矩阵 UI
- 测试边界 case：空话题、超长回答、网络断连、模型 crash
- Android 真机/模拟器跑通
- 修复双端差异问题

**Day 8 — 模型下载 ✅**

- HuggingFace 直链获取
- dio 断点续传实现
- 下载进度 Provider → UI 进度条
- 下载完成自动触发模型加载

**Day 9 — 收尾 ✅**

- 写 README（架构图 + 截图 + 技术栈 + 快速开始）
- 录 2 分钟 Demo 视频
- 截图（6 个页面 + 错误状态）
- Push GitHub
- 写一句话简历描述

---

## 九、面试话术准备

### 简历落点

> 独立开发基于 Flutter + llama.cpp 的苏格拉底式 AI 对话应用，通过 Dart FFI 桥接 Qwen3.5-2B 端侧推理引擎，Metal/CoreML 自动加速；端侧 LLM 驱动追问策略、洞察总结与思维图谱生成；完整数据本地持久化，隐私零上传；一个代码库覆盖双端从 UI 到推理的完整链路。

### 高频追问 + 标准回答

| 面试官问 | 你的回答方向 |
|------|------|
| 「为什么是苏格拉底式对话，有什么特别？」 | 99% 的 AI 产品是「你问它答」，我们是反向的。AI 追问用户的底层假设，帮助用户独立思考。产品形态决定了技术挑战——Prompt 工程从「准确回答」变成「精准追问」，难度不同 |
| 「1.5B 模型怎么做追问？质量够吗？」 | 追问比回答简单——问一个好问题不需要太多知识，需要的是对用户上一条回答的分析能力。加上 Dart 层追问策略辅助 Prompt，实测 80% 追问是合理且有深度的。质量不够的 20% 做了容错兜底 |
| 「为什么用 Dart FFI 不用 MethodChannel？」 | 跨平台一致性：一份 Dart 代码双端共享推理逻辑，MethodChannel 需要 Swift + Kotlin 两套 Native 代码 |
| 「端侧推理和云端 API 的边界怎么划分？」 | 核心对话在端侧——隐私敏感，需要低延迟实时追问。后端只存脱敏后的结构化数据（话题、洞察、图谱节点），不存原始对话内容 |
| 「思维图谱怎么做出来的？」 | 端侧 LLM（Qwen3.5-2B）直接分析对话输出 JSON 图谱结构，Dart 侧实现辐射分布布局算法计算节点坐标（无需 dagre 等外部库），Flutter CustomPainter 渲染可交互可视化（支持拖拽节点、双指缩放、点击详情） |
| 「如果用户回答很短或者敷衍怎么办？」 | Prompt 里有追问具体化的规则（「能举一个具体例子吗？」），Dart 层也会检测回答长度，太短则自动注入追问策略提示 |
| 「为什么用 Go 写后端？」 | IM 背景下习惯了高并发场景思考。Go 轻量（单二进制部署）、协程天然高并发、编译快迭代快，适合 MVP 阶段快速验证 |

---

## 十、技术栈清单

| 层 | 技术 | 用途 |
|------|------|------|
| UI 框架 | Flutter 3.x | 跨平台 iOS + Android |
| 状态管理 | Provider | 对话状态 + 推理状态 |
| 推理引擎 | llama.cpp (C++) | CMake 编译进 App |
| Dart 桥接 | dart_llama (Dart FFI) | Dart → C++ 推理调用 |
| 模型 | Qwen3.5-2B Instruct (Q4_K_M) | 中文苏格拉底对话 |
| iOS 加速 | CoreML backend（llama.cpp 内置） | 自动启用 ANE |
| Android 加速 | NNAPI backend（llama.cpp 内置） | 自动启用 NPU |
| 模型托管 | HuggingFace | GGUF 直链下载 |
| 下载 | dio (HTTP + 断点续传) | 模型下载 |
| HTTP | dio | 后端 API 调用 |
| 后端语言 | Go | REST API |
| 后端框架 | Gin | HTTP 路由 |
| ORM | GORM | 数据库操作 |
| 数据库 | SQLite (MVP) → PostgreSQL (生产) | 持久化 |
| 图谱布局 | Dart 辐射分布 + 微力调整 | 思维图谱节点坐标（纯端侧，无外部库） |
| 图谱渲染 | Flutter CustomPainter | 交互式可视化 + 手势 |

---

## 十一、风险与对策

| 风险 | 概率 | 对策 |
|------|:--:|------|
| Qwen 2B 苏格拉底追问质量不够 | 中 | 加强 Dart 层追问策略；备选 Qwen 3B（质量更好但模型更大） |
| dart_llama 包不成熟 | 中 | 备选手写 `dart:ffi` binding llama.cpp C API，约 200 行 |
| 模型 1.06GB 下载太慢 | 中 | HuggingFace 直链 + 断点续传 + 进度条 |
| 10 天太紧 | 中 | 后端思维图谱可降级为「规则引擎关键词匹配」而非真实 LLM 分析 |
| 中文追问老是重复 | 低 | repeat_penalty 1.15 + Prompt 里强化「不要重复上一个问题」 |
| Android 碎片化兼容 | 低 | 主流 Android 10+ 设备 NNAPI 基本可用；无 NPU 降级 CPU |
| Go 后端时间不够 | 低 | Day 5-7 是后端核心三天，可先做最小 API（CRUD + 图谱规则引擎） |

---

## 附录：与群聊摘要器的差异总结

| 维度 | 群聊摘要器 | 苏格拉底 AI |
|------|------|------|
| 产品形态 | 工具型（用完即走） | 陪伴型（深度对话） |
| AI 角色 | 总结者（被动） | 追问者（主动） |
| 展示性 | 输入→输出，平铺直叙 | AI 问你问题，体验有冲击力 |
| Prompt 难度 | 结构化 JSON 输出 | 开放式追问，需要策略辅助 |
| Demo 话题 | 「技术方案不错」 | 「这个产品本身就有意思」 |
| 后端角色 | 不需要 | 同步 + 图谱，自然带出后端能力 |
