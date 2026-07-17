# 军师 AI — 完整产品形态实现计划

> **For WorkBuddy:** Use `executing-plans` skill to implement this plan task-by-task.

**Goal:** 实现 2026-07-17 讨论确定的完整产品闭环：Prompter 注入上下文 → Extractor 只提议不修改 → Brief 页确认 → Dashboard 状态流转 + 级联

**Architecture:** 分 7 个独立 task，按依赖顺序排列。每个 task 完成后 `flutter analyze` 必须零 issue。

**Tech Stack:** Flutter 3.x + Provider + sqflite + llama.cpp (Qwen3.5-2B)

**前置条件：**
- PROJECT.md 已更新（本轮已完成）
- `GoalStatus.proposed` 枚举值需新增
- Dashboard 三区 + StrategyTimeline 已就位

---

### Task 1: Goal 模型加 proposed 状态 + DB migration

**Files:**
- Modify: `lib/core/models/dashboard_models.dart` — 枚举加 `proposed`
- Modify: `lib/core/repository/dashboard_repository.dart` — migration 加 proposed 列

**Step 1: 枚举加 proposed**

在 `GoalStatus` 枚举中最前面加 `proposed`：

```dart
enum GoalStatus {
  proposed,  // 新增：AI 提议，待用户确认
  active,
  completed,
  paused,
}
```

`proposed` 排最前面，确保 `GoalStatus.values` 索引从它开始（DB 里默认值 0 即 proposed）。

**Step 2: 更新 parse 逻辑**

`_parseStatus` 方法中 `orElse: () => GoalStatus.active` 保持不变——新创建的目标显示值时用枚举名映射，不受影响。

**Step 3: DB migration 检查**

DashboardRepository 的 `openDashboardDb` 使用了 `IF NOT EXISTS` 建表，`status TEXT NOT NULL DEFAULT 'active'`。需要改为 `DEFAULT 'proposed'`，已有数据的 `active` 不受影响（已有行的 status 已写入）。

```dart
// 修改 goals 表的建表语句
status TEXT NOT NULL DEFAULT 'proposed',
```

**Step 4: DashboardProvider 适配**

`DashboardProvider.activeGoalCount` 当前统计 `status == GoalStatus.active`，proposed 不计入，符合预期。

`DashboardProvider.load` 中 `getAllGoals` 默认返回所有 goal。需要新增一个 filter 方法：

```dart
// dashboard_repository.dart
Future<List<Goal>> getActiveGoals() async {
  final db = await openDashboardDb();
  final rows = await db.query('goals',
      where: 'status = ?', whereArgs: ['active']);
  return rows.map((row) => Goal.fromMap(row)).toList();
}
```

**Step 5: 验证**

```bash
flutter analyze lib/
```
Expected: No issues.

---

### Task 2: Extractor prompt 更新 — 只提议不修改

**Files:**
- Modify: `lib/core/engine/strategist_extractor.dart`

**当前问题：** Extractor prompt 允许 LLM 输出 `goal_updates` 自动修改目标状态，且 `new_goals` 无 proposed 概念。

**Step 1: 更新 prompt 中的 goal_updates 部分**

找到 prompt 模板中的 goal_updates 字段描述，改为：

```
goal_updates:
{"goal_title":"已有目标标题(精确匹配)","suggested_status":"completed|paused","reason":"建议原因"}
# 注意：这些是「建议」，不会自动生效，需要用户确认
# 只能建议 status 变更，不允许建议修改 title/category/priority
```

**Step 2: 新增 new_goals 的 status 字段**

```json
new_goals:
{"title":"...","category":"career|finance|relationship|health|growth|other","priority":1-5,"deadline":null或"2026-09-01","notes":"..."}
# 新增目标初始状态为 proposed，需用户确认后变为 active
```

**Step 3: 更新 ExtractionResult 模型**

检查 `StrategistExtractor` 中的 `ExtractionResult` 类，确保 `new_goals` 解析时 status 默认为 `proposed`。

```dart
// 在解析 new_goals 时
Goal(
  title: goalJson['title'],
  category: _parseCategory(goalJson['category']),
  status: GoalStatus.proposed,  // 硬编码 proposed
  priority: goalJson['priority'] ?? 3,
  deadline: goalJson['deadline'],
  notes: goalJson['notes'],
  ...
)
```

**Step 4: 验证**

```bash
flutter analyze lib/
```
Expected: No issues.

---

### Task 3: Brief 页重构 — 三区 + 点击即生效

**Files:**
- Modify: `lib/features/strategy_brief/strategy_brief_page.dart` — 全新布局
- Modify: `lib/features/strategy_brief/providers/strategy_brief_provider.dart` — 加 confirm/ignore 方法
- Create: `lib/features/strategy_brief/widgets/new_goal_card.dart` — 新目标卡片（[确认]/[忽略]）
- Create: `lib/features/strategy_brief/widgets/goal_update_card.dart` — 已有目标变更卡片
- Create: `lib/features/strategy_brief/widgets/insight_card.dart` — 洞察卡片（[删除]）
- Create: `lib/features/strategy_brief/strategy_detail_page.dart` — 策略二级页

**当前实现：** StrategyBriefPage 是一个简单的提取结果展示页，没有交互。

**Step 1: Provider 加操作方法**

```dart
// StrategyBriefProvider 新增
void confirmNewGoal(int index) { ... }   // proposed → active，写 DB
void ignoreNewGoal(int index) { ... }    // 丢弃 proposed
void confirmGoalUpdate(int index) { ... } // 执行建议的 status 变更
void ignoreGoalUpdate(int index) { ... }  // 忽略建议
void deleteInsight(int index) { ... }     // 删除 cross_pattern
```

每个操作方法内部：
1. 更新本地 state（从列表中移除该条目）
2. 调用 DashboardRepository 写 DB
3. `notifyListeners()`

点击即生效，无弹窗。

**Step 2: BriefPage 三区布局**

```dart
_buildBody(StrategyBriefState state) {
  if (state.isExtracting) return _buildLoading();

  return ListView(
    padding: const EdgeInsets.all(16),
    children: [
      _buildSummaryHeader(state),  // "本次对话产生了 X 个建议"

      // Zone 1: 新目标
      if (state.newGoals.isNotEmpty) ...[
        _sectionHeader('🎯 新目标', Icons.flag_rounded),
        ...state.newGoals.asMap().entries.map((e) => 
          NewGoalCard(goal: e.value, onConfirm: () => _provider.confirmNewGoal(e.key), onIgnore: () => _provider.ignoreNewGoal(e.key)),
        ),
      ],

      // Zone 2: 已有目标变更
      if (state.goalUpdates.isNotEmpty) ...[
        _sectionHeader('🔄 已有目标变更', Icons.update_rounded),
        ...state.goalUpdates.asMap().entries.map((e) =>
          GoalUpdateCard(update: e.value, onTapStrategy: () => _openStrategyDetail(e.value), onConfirm: ..., onIgnore: ...),
        ),
      ],

      // Zone 3: 洞察
      if (state.insights.isNotEmpty) ...[
        _sectionHeader('💡 洞察', Icons.lightbulb_rounded),
        ...state.insights.asMap().entries.map((e) =>
          InsightCard(insight: e.value, onDelete: () => _provider.deleteInsight(e.key)),
        ),
      ],
    ],
  );
}
```

**Step 3: 策略二级页**

```dart
class StrategyDetailPage extends StatelessWidget {
  final Goal goal;
  final List<Strategy> strategies;

  // 展示该目标下的所有策略列表（只读）
  // 每条策略显示 description + type 图标 + completed 状态
}
```

GoalUpdateCard 右侧显示箭头图标（`Icons.chevron_right`），点击跳转。

**Step 4: 无提取内容时的处理**

如果 Extractor 返回 null 或 relevant=false，显示：
```
"这次对话没有产生新的目标建议"
[返回大局观]
```

**Step 5: 验证**

```bash
flutter analyze lib/
```
Expected: No issues.

---

### Task 4: Dashboard 弹窗确认 — Goal 状态 + Strategy toggle

**Files:**
- Modify: `lib/features/dashboard/dashboard_page.dart` — 加弹窗逻辑
- Modify: `lib/features/dashboard/providers/dashboard_provider.dart` — 加 toggle 方法
- Modify: `lib/features/dashboard/widgets/goal_card.dart` — GoalCard 的 status icon 可点击

**Step 1: DashboardProvider 加方法**

```dart
// dashboard_provider.dart 新增

Future<void> toggleGoalStatus(int goalId, GoalStatus newStatus) async {
  final goal = _state.goals.firstWhere((g) => g.id == goalId);

  // 级联逻辑（见 Task 5）
  if (newStatus == GoalStatus.completed) {
    // 下属策略全标记 completed
  } else if (newStatus == GoalStatus.paused) {
    // 策略保持原状，但执行路线过滤掉
  }

  await _repo.updateGoalStatus(goalId, newStatus);
  await load(); // 重新加载全量数据
}

Future<void> toggleStrategy(int strategyId, bool completed) async {
  await _repo.updateStrategyCompleted(strategyId, completed);
  await load();
}
```

**Step 2: DashboardRepository 加方法**

```dart
// dashboard_repository.dart 新增

Future<void> updateGoalStatus(int goalId, GoalStatus status) async {
  final db = await openDashboardDb();
  await db.update('goals', {'status': status.name, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?', whereArgs: [goalId]);
}

Future<void> updateStrategyCompleted(int strategyId, bool completed) async {
  final db = await openDashboardDb();
  await db.update('strategies', {'completed': completed ? 1 : 0},
      where: 'id = ?', whereArgs: [strategyId]);
}
```

**Step 3: DashboardPage 加弹窗**

```dart
void _showGoalStatusDialog(Goal goal) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('修改目标状态'),
      content: Text('将「${goal.title}」标记为？'),
      actions: [
        if (goal.status == GoalStatus.active) ...[
          TextButton(onPressed: () { _provider.toggleGoalStatus(goal.id!, GoalStatus.paused); Navigator.pop(ctx); }, child: Text('暂停')),
          TextButton(onPressed: () { _provider.toggleGoalStatus(goal.id!, GoalStatus.completed); Navigator.pop(ctx); }, child: Text('完成')),
        ],
        if (goal.status == GoalStatus.paused)
          TextButton(onPressed: () { _provider.toggleGoalStatus(goal.id!, GoalStatus.active); Navigator.pop(ctx); }, child: Text('恢复')),
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text('取消')),
      ],
    ),
  );
}

void _showStrategyToggleDialog(Strategy strategy) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(strategy.completed ? '取消完成' : '确认完成'),
      content: Text('「${strategy.description}」'),
      actions: [
        TextButton(
          onPressed: () { _provider.toggleStrategy(strategy.id!, !strategy.completed); Navigator.pop(ctx); },
          child: Text('确认'),
        ),
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text('取消')),
      ],
    ),
  );
}
```

**Step 4: GoalCard 加可点击区域**

在 GoalCard 的 status icon（那个小圆点/勾号）外包 `GestureDetector`，点击触发 `onStatusTap` 回调。DashboardPage 传入 `_showGoalStatusDialog(goal)`。

Strategy checkbox 同样加 `GestureDetector`，点击触发弹窗。

**Step 5: 验证**

```bash
flutter analyze lib/
```
Expected: No issues.

---

### Task 5: 级联逻辑

**Files:**
- Modify: `lib/features/dashboard/providers/dashboard_provider.dart`

**Step 1: toggleGoalStatus 加级联**

```dart
Future<void> toggleGoalStatus(int goalId, GoalStatus newStatus) async {
  if (newStatus == GoalStatus.completed) {
    // 该目标下所有策略标记为 completed
    final strategies = _state.strategies.where((s) => s.goalId == goalId);
    for (final s in strategies) {
      await _repo.updateStrategyCompleted(s.id!, true);
    }
  }
  // paused 不需要改策略 completed 状态，只需要在 Timeline 过滤

  await _repo.updateGoalStatus(goalId, newStatus);
  await load();
}
```

**Step 2: DashboardRepository 加批量方法**

```dart
Future<void> completeAllStrategiesForGoal(int goalId) async {
  final db = await openDashboardDb();
  await db.update('strategies', {'completed': 1},
      where: 'goal_id = ?', whereArgs: [goalId]);
}
```

**Step 3: 验证**

```bash
flutter analyze lib/
```
Expected: No issues.

---

### Task 6: StrategyTimeline 过滤 — 只显示活跃目标的未完成策略

**Files:**
- Modify: `lib/features/dashboard/widgets/strategy_timeline.dart`

**当前实现：** Timeline 只过滤 `!completed`，但没有过滤目标状态（paused 目标的策略也会出现）。

**Step 1: 加目标状态过滤**

```dart
final pending = strategies.where((s) {
  if (s.completed) return false;
  final goal = goalMap[s.goalId];
  if (goal == null) return false;
  return goal.status == GoalStatus.active;  // 只显示活跃目标
}).toList();
```

**Step 2: 验证**

```bash
flutter analyze lib/
```
Expected: No issues.

---

### Task 7: Prompter 注入已有目标 + 合并检测

**Files:**
- Modify: `lib/features/chat/engine/strategist_prompter.dart`
- Modify: `lib/features/chat/providers/chat_provider.dart`
- Modify: `lib/core/repository/dashboard_repository.dart`

**Step 1: Prompter 支持注入目标上下文**

在 `StrategistPrompter` 的 `buildSystemPrompt` 方法中新增 `existingGoals` 参数：

```dart
String buildSystemPrompt({
  String? topic,
  List<Goal> existingGoals = const [],
}) {
  final goalContext = existingGoals.isEmpty
    ? ''
    : '\n## 主公已有目标\n${existingGoals.map((g) => "- [${g.status}] ${g.title}").join('\n')}\n';

  return '''你是军师...
$goalContext
## 对话规则
- 先追问理解主公需求，再给建议
- 如果主公的新想法与已有目标相似，建议合并而非新建
- 你可以提议目标，但最终需要主公确认
...''';
}
```

**Step 2: ChatProvider 注入已有目标**

在 `ChatProvider` 初始化或 `seedHistory` 时，通过 `DashboardRepository.getAllActiveGoals()` 获取活跃目标列表，传给 Prompter。

```dart
// chat_provider.dart
import 'package:socratic_ai/core/repository/dashboard_repository.dart';

final _dashboardRepo = DashboardRepository();

Future<void> seedHistory(Conversation? conversation) async {
  final activeGoals = await _dashboardRepo.getActiveGoals();
  final prompt = _prompter.buildSystemPrompt(
    topic: _topic,
    existingGoals: activeGoals,
  );
  _engine.setSystemPrompt(prompt);
  ...
}
```

注意：ChatProvider 不符合分层规范（provider 不能直接 import repository）。但 DashboardRepository 已在 core/repository/ 下，属于允许范围（providers → repository / models / core）。

**Step 3: 验证**

```bash
flutter analyze lib/
```
Expected: No issues.

---

## 执行顺序

Task 1 → 2 → 3 → 4 → 5 → 6 → 7

Task 1-2 是基础（模型 + Extractor），Task 3 是核心 UI 改动（Brief 页），Task 4-6 是 Dashboard 交互增强，Task 7 是对话层改进。建议严格按顺序执行，因为后面 task 依赖前面 task 的模型定义。

## 验证标准

每个 task 完成后：
1. `flutter analyze lib/` — 零 issue
2. 代码符合分层规范（page→provider→engine/repository→models/core）
3. 文件首行 import，无空行在前
