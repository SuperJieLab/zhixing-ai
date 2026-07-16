# 军师模式 & 全局面板 — 设计文档

> 状态：设计阶段（Brainstorming 完成） | 2026-07-16

---

## 1. 产品定位

从"苏格拉底教练"（反思过去）切换为"军师/谋士"（规划未来）。

核心体验闭环：

```
主公表达诉求 → 军师理解意图 → 目标拆解 → 策略生成 → 执行追踪 → 主动提醒
```

**关键设计原则**：每次对话结束后，LLM 提取本次对话中涉及的**目标、策略、约束**，
汇入全局面板（Dashboard）。面板自动合并、去重、跨对话关联，形成"主公的全局态势图"。

---

## 2. 导航流

```
App 启动
  │
  └── DashboardPage（唯一主页）
        │
        ├── [+] 新对话 → ChatPage（军师模式，StrategistPrompter）
        │     │
        │     └── 结束对话 → StrategyBriefPage
        │           │   ├── relevant: true  → 展示目标/策略/跨对话发现
        │           │   └── relevant: false → 轻量对话总结 + "返回大局观"
        │           │
        │           └── "返回大局观" → popUntil(Dashboard)
        │
        ├── Goal 卡片 → 暂时无交互（后续扩展专用承载页）
        └── 历史入口 → HistoryPage（保留现有流程）
```

**旧页面处理**：InsightsPage、MindMapPage、TopicSelectionPage 移入 `_deprecated/`，
代码保留不删，不接入任何 UI。

---

## 3. 目录结构

```
lib/features/
├── _deprecated/                     ← 新增，存放退出主流程的旧代码
│   ├── insights/                    # InsightsPage + engine + provider + widgets
│   ├── mindmap/                     # MindMapPage + engine + layout + provider + widgets
│   └── topics/                      # TopicSelectionPage + widgets
│
├── chat/                            # 活跃 — 军师模式对话
│   ├── engine/
│   │   ├── socratic_prompter.dart   # 保留不动（代码留存）
│   │   └── strategist_prompter.dart # 新增 — 军师 prompt（AI 主动给分析+策略）
│   ├── providers/
│   │   └── chat_provider.dart       # 改为使用 StrategistPrompter
│   ├── widgets/
│   └── chat_page.dart               # 结束对话 → StrategyBriefPage
│
├── dashboard/                       # 新增 — 全局面板
│   ├── engine/
│   │   └── strategist_extractor.dart # LLM 提取 goals/strategies（含相关性判断）
│   ├── providers/
│   │   └── dashboard_provider.dart   # 全局态势状态管理
│   ├── widgets/
│   │   ├── goal_card.dart
│   │   ├── strategy_item.dart
│   │   ├── cross_pattern_card.dart
│   │   └── dashboard_header.dart
│   └── dashboard_page.dart
│
├── strategy_brief/                  # 新增 — 对话结束后的大局影响页
│   ├── providers/
│   │   └── strategy_brief_provider.dart
│   ├── widgets/
│   └── strategy_brief_page.dart
│
├── history/                         # 活跃
├── mindmap/                         # → 移到 _deprecated
└── model_manager/                   # 活跃
```

**core 层新增**：

```
lib/core/
├── engine/
│   └── strategist_extractor.dart    # 或放在 dashboard/engine/
├── models/
│   └── dashboard_models.dart        # Goal / Strategy / CrossPattern
└── repository/
    └── dashboard_repository.dart    # goals / strategies / cross_patterns CRUD
```

---

## 4. 数据模型

### 4.1 新增实体

```dart
// lib/core/models/dashboard_models.dart

enum GoalCategory {
  career,        // 职业
  finance,       // 财务
  relationship,  // 人际
  health,        // 健康
  growth,        // 成长/学习
  other,         // 其他
}

enum GoalStatus {
  active,        // 活跃
  completed,     // 已完成
  paused,        // 搁置
}

enum StrategyType {
  selfAction,    // 主公自行执行
  aiAssist,      // 军师可协助
  externalDep,   // 依赖外因
}

class Goal {
  int? id;
  String title;
  GoalCategory category;
  GoalStatus status;
  int? priority;           // 1-5
  List<int> sourceConvIds; // 来源对话 ID
  String? deadline;
  String? notes;
  DateTime createdAt;
  DateTime updatedAt;
}

class Strategy {
  int? id;
  int goalId;
  String description;
  StrategyType type;
  String? nextStep;
  bool completed;
  DateTime? nextReminder;  // 服务端阶段启用
  DateTime createdAt;
}

class CrossPattern {
  int? id;
  String label;
  String description;
  List<int> sourceConvIds;
  int frequency;
  DateTime detectedAt;
}
```

### 4.2 DB 新增表

```sql
CREATE TABLE goals (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  category TEXT NOT NULL DEFAULT 'other',
  status TEXT NOT NULL DEFAULT 'active',
  priority INTEGER DEFAULT 3,
  source_conv_ids TEXT NOT NULL DEFAULT '[]',
  deadline TEXT,
  notes TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE strategies (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  goal_id INTEGER NOT NULL,
  description TEXT NOT NULL,
  type TEXT NOT NULL DEFAULT 'selfAction',
  next_step TEXT,
  completed INTEGER NOT NULL DEFAULT 0,
  next_reminder TEXT,
  created_at TEXT NOT NULL,
  FOREIGN KEY (goal_id) REFERENCES goals(id)
);

CREATE TABLE cross_patterns (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  label TEXT NOT NULL,
  description TEXT,
  source_conv_ids TEXT NOT NULL DEFAULT '[]',
  frequency INTEGER NOT NULL DEFAULT 1,
  detected_at TEXT NOT NULL
);
```

---

## 5. 数据流

```
┌─────────────┐     ┌─────────────────────┐     ┌────────────────┐
│  ChatPage   │────→│ StrategistExtractor │────→│ Dashboard      │
│  (军师模式) │     │ (相关性判断 + 提取) │     │ Provider       │
└─────────────┘     └─────────────────────┘     └────────────────┘
                            │                          │
                        finishConversation          merge / dedup
                            │                          │
                            ▼                          ▼
                     ┌──────────────┐           ┌──────────────┐
                     │  DB:         │           │  DB:         │
                     │  conversations│           │  goals +     │
                     │              │           │  strategies  │
                     └──────────────┘           └──────────────┘
```

### 5.1 对话结束流程

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
  │
  ├── 3) DashboardProvider.merge(result)
  │      ├── 同名 goal → 合并 sourceConvIds
  │      ├── 新 strategy → 追加
  │      └── cross pattern → 追加/更新
  │
  └── 4) Navigator.pushReplacement → StrategyBriefPage
         传入 currentConversation + extractionResult（可为 null）
```

### 5.2 全局面板加载

```
DashboardPage.initState()
  └── DashboardProvider.load()
        ├── goals (from DB)
        ├── strategies (from DB, grouped by goal)
        └── crossPatterns (from DB)
```

---

## 6. LLM Prompt 设计

### 6.1 军师对话 Prompt（StrategistPrompter）

替换原有苏格拉底追问 prompt。AI 在对话中主动给分析、建议、拆解。

```
你是一位经验丰富的军师。主公来找你商量事情时，你的职责是：

1. 先理解主公的真实处境和核心诉求
2. 帮主公把模糊的问题拆解成清晰的子问题
3. 给出具体的分析和可执行的策略建议
4. 区分"主公自己能做的"和"需要外部条件配合的"
5. 在适当时候追问，帮助主公想得更深

风格要求：
- 像朋友一样真诚，不端着
- 给具体建议，不说空话
- 分析为什么这样建议，让主公理解背后的逻辑
- 每次回复控制在 3-5 句话内，简洁有力
```

### 6.2 StrategistExtractor — 相关性判断 + 提取

```
你是一位军师。请首先判断以下对话是否包含值得关注的目标或策略。

如果对话内容为纯闲聊、情绪发泄（无进一步展开）、短试探，
或没有任何可执行的信息，请直接输出：
{"relevant": false}

如果对话包含实质内容，请提取目标、策略和关键信息，输出：
{
  "relevant": true,
  "new_goals": [...],
  "goal_updates": [...],
  "strategies": [...],
  "cross_patterns": [...]
}

提取要求：
1. 识别主公表达的目标（显性或隐性）
2. 同名目标自动合并（视为同一目标的补充），标注更新而非新建
3. 为每个目标建议 1-3 条可执行策略
4. 标注每条策略类型：selfAction / aiAssist / externalDep
5. 发现跨对话的模式或矛盾
6. 严格只输出 JSON，不要带 markdown 代码块标记

new_goals:
{"title":"...","category":"career|finance|relationship|health|growth|other","priority":1-5,"deadline":null或"2026-09-01","notes":"..."}

goal_updates:
{"goal_title":"已有目标标题(精确匹配)","new_status":"active|completed|paused","new_notes":"...","reason":"为什么更新"}

strategies:
{"goal_title":"关联的目标标题","description":"...","type":"selfAction|aiAssist|externalDep","next_step":"下一步具体动作"}

cross_patterns:
{"label":"模式名称","description":"详细描述"}
```

### 6.3 提取实现

```dart
Future<ExtractionResult?> extract(Conversation conv, List<Goal> existingGoals) async {
  // 前置检查：对话太短直接跳过
  if (conv.messages.where((m) => m.role == MessageRole.user).length < 2) {
    return null;
  }

  final prompt = '''
## 主公已有的目标
${existingGoals.map((g) => "- [${g.status}] ${g.title}").join('\n')}

## 本轮对话
${buildConversationText(conv.topic, conv.messages)}
''';

  final rawJson = await _callLLM(prompt);
  final parsed = jsonDecode(stripThinkTags(rawJson));

  if (parsed['relevant'] != true) return null;
  return ExtractionResult.fromJson(parsed);
}
```

---

## 7. StrategyBriefPage 设计

### 7.1 页面行为

| 场景 | 展示内容 |
|------|---------|
| extractionResult != null | 新目标卡片 + 已有目标更新 + 新增策略列表 + 跨对话发现 |
| extractionResult == null | 轻量对话总结（"你这次聊了XX，虽然没产生具体目标..."）+ 空状态 |
| 加载中 | 骨架屏 / 加载动画 |

### 7.2 UI 布局（有提取结果时）

```
┌─────────────────────────────────────┐
│  ← 返回        大局影响             │
├─────────────────────────────────────┤
│                                     │
│  🎯 新目标                          │
│  ┌─────────────────────────────┐   │
│  │ 跳槽到更好的平台    职业  P4 │   │
│  │ 建议策略:                   │   │
│  │  ▢ 每周投递 3 家目标公司     │   │
│  │  ▢ 整理项目成果数据          │   │
│  └─────────────────────────────┘   │
│                                     │
│  📋 已更新目标                      │
│  ┌─────────────────────────────┐   │
│  │ 改善与领导的沟通  → 已完成  │   │
│  │ "上次提到的方法奏效了"      │   │
│  └─────────────────────────────┘   │
│                                     │
│  🔍 跨对话发现                      │
│  "你最近 3 次对话都提到「钱不够」  │
│   但从未制定具体财务目标"           │
│                                     │
│  [返回大局观]                       │
└─────────────────────────────────────┘
```

### 7.3 返回行为

"返回大局观"按钮 → `Navigator.of(context).popUntil((route) => route.isFirst)`

ChatPage 和 StrategyBriefPage 一起出栈，用户回到 Dashboard。

---

## 8. 全局面板 UI 布局

```
┌─────────────────────────────────────────┐
│  📊 大局观                      [+ 新对话] │
├─────────────────────────────────────────┤
│                                         │
│  ┌─── 统计概览 ───────────────────┐     │
│  │  3 活跃目标  ·  5 待执行  ·  2 发现  │     │
│  └────────────────────────────────┘     │
│                                         │
│  🎯 活跃目标                            │
│  ┌────────────────────────────────┐    │
│  │ ● 跳槽到更好的平台    职业  P4  │    │
│  │   来源: 2 次对话               │    │
│  │   策略: ▢ 更新简历             │    │
│  │         ▢ 约 mentor 喝咖啡     │    │
│  │         ☑ 整理项目成果数据     │    │
│  │   [展开 ▼]                     │    │
│  └────────────────────────────────┘    │
│  ┌────────────────────────────────┐    │
│  │ ◐ 改善与领导的沟通    人际  P3  │    │
│  │   ...                          │    │
│  └────────────────────────────────┘    │
│                                         │
│  🔍 跨对话发现                          │
│  ┌────────────────────────────────┐    │
│  │ 💡 "你最近 3 次对话都提到       │    │
│  │     「钱不够」，但从未制定       │    │
│  │     具体财务目标"               │    │
│  └────────────────────────────────┘    │
│                                         │
└─────────────────────────────────────────┘
```

---

## 9. 实现顺序

| Phase | 内容 | 依赖 |
|-------|------|------|
| 0 | 目录重组 — insights/mindmap/topics → `_deprecated/` | 无 |
| 1 | `dashboard_models.dart` + `dashboard_repository.dart` + DB 建表 | Phase 0 |
| 2 | `StrategistExtractor` — LLM prompt + JSON 解析 + 相关性判断 | Phase 1 |
| 3 | `DashboardProvider` — merge 逻辑 + 加载 | Phase 1, 2 |
| 4 | `StrategistPrompter` — 军师对话 prompt | 无（独立文件） |
| 5 | `ChatProvider` — 切换为 StrategistPrompter | Phase 4 |
| 6 | `StrategyBriefPage` + `StrategyBriefProvider` | Phase 2, 3 |
| 7 | `ChatPage._endConversation` — 走新流程 | Phase 5, 6 |
| 8 | `DashboardPage` + widgets | Phase 3 |
| 9 | `main.dart` — 入口切换为 DashboardPage | Phase 8 |
| 10 | 清理 — 旧 main.dart 代码、旧路由 | Phase 9 |
| 11 | （服务端阶段）推送提醒、定时任务 | 服务端就绪后 |

---

## 10. 已决策事项汇总

| 问题 | 决策 |
|------|------|
| 主页 | DashboardPage **唯一主页**，TopicSelection 进入 `_deprecated` |
| 新对话入口 | Dashboard [+] 按钮 → ChatPage |
| Goal 卡片交互 | 暂不交互，后续扩展专用承载页 |
| 对话模式 | 切换为军师模式（**StrategistPrompter**），SocraticPrompter 代码保留 |
| 对话结束流向 | ChatPage → **StrategyBriefPage**（新页面） |
| 旧 InsightsPage | 代码保留，移入 `_deprecated`，不接入 UI |
| 旧 MindMapPage | 代码保留，移入 `_deprecated`（孤儿页面，无入口） |
| 旧 TopicSelectionPage | 代码保留，移入 `_deprecated` |
| relevant=false 时 | 仍进 StrategyBriefPage，展示轻量总结 + "返回大局观" |
| 返回 Dashboard | `popUntil(isFirst)`，ChatPage 和 StrategyBriefPage 一起出栈 |
| Goal 去重 | 相同 title 自动合并 sourceConvIds |
| 提取频率 | 每次对话结束都提取 |
| 用户编辑 | 全 AI 管理，不允许手动增删改 |
| 提醒 | 服务端就绪前用 flutter_local_notifications |
| 相关性判断 | < 2 条用户消息跳过，否则 LLM 判断 `relevant` 字段 |
