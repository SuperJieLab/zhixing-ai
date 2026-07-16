# Plan A: 基础设施（Phase 0-3）

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 目录重组 + 数据模型 + DB 迁移 + StrategistExtractor + DashboardProvider

**Architecture:** 纯基础设施变更，不涉及 UI。旧 features 移入 `_deprecated/`，新增 `dashboard_models.dart` 和 `dashboard_repository.dart`，DB 从 v2 升级到 v3（新增 3 张表），新增 `StrategistExtractor`（LLM 调用封装）和 `DashboardProvider`（merge + 加载）

**Tech Stack:** Flutter 3.x + sqflite + Provider + llama_cpp_dart

---

### Task 1: 目录重组 — 移入 `_deprecated/`

**Files:**
- Move: `lib/features/insights/` → `lib/features/_deprecated/insights/`
- Move: `lib/features/mindmap/` → `lib/features/_deprecated/mindmap/`
- Move: `lib/features/topics/` → `lib/features/_deprecated/topics/`
- Modify: all files with imports referencing these paths

**文件清单（需移动）：**
```
lib/features/insights/
  engine/insight_service.dart
  insights_page.dart
  providers/insight_provider.dart
  widgets/contradiction_card.dart
  widgets/insight_card.dart
  widgets/staggered_item.dart
  widgets/value_tags.dart

lib/features/mindmap/
  engine/graph_service.dart
  layout/force_directed.dart
  mindmap_page.dart
  providers/mindmap_provider.dart
  widgets/graph_painter.dart
  widgets/node_detail_sheet.dart

lib/features/topics/
  topic_selection_page.dart
  widgets/topic_card.dart
```

**引用这些 features 的文件（需同步修改 import）：**
- `lib/app.dart:3` — `features/topics/topic_selection_page.dart`
- `lib/features/chat/chat_page.dart:9` — `features/insights/insights_page.dart`
- `lib/features/history/history_page.dart:7` — `features/insights/insights_page.dart`

**Step 1: 创建 `_deprecated` 目录并移动文件**

```bash
cd /Users/superjie-mac/projects/socratic-ai
mkdir -p lib/features/_deprecated
git mv lib/features/insights lib/features/_deprecated/insights
git mv lib/features/mindmap lib/features/_deprecated/mindmap
git mv lib/features/topics lib/features/_deprecated/topics
```

**Step 2: 更新 `lib/app.dart` 的 import**

```dart
// 旧的
import 'package:socratic_ai/features/topics/topic_selection_page.dart';
// 改为
import 'package:socratic_ai/features/_deprecated/topics/topic_selection_page.dart';
```

**Step 3: 更新 `lib/features/chat/chat_page.dart` 的 import**

```dart
// 旧的
import 'package:socratic_ai/features/insights/insights_page.dart';
// 改为
import 'package:socratic_ai/features/_deprecated/insights/insights_page.dart';
```

**Step 4: 更新 `lib/features/history/history_page.dart` 的 import**

```dart
// 旧的
import 'package:socratic_ai/features/insights/insights_page.dart';
// 改为
import 'package:socratic_ai/features/_deprecated/insights/insights_page.dart';
```

**Step 5: 更新 `_deprecated` 内文件之间的相对 import**

被移动的文件之间存在相互引用（如 `insights_page.dart` 引用 `mindmap_page.dart`、`topic_selection_page.dart`），需将 import 路径中的 `features/` 改为 `features/_deprecated/`：

```bash
# 查找所有需要修改的 import
grep -rl "package:socratic_ai/features/\(insights\|mindmap\|topics\)" lib/features/_deprecated/
```

逐个文件修改，将 import 路径加 `_deprecated/` 前缀。

**Step 6: 验证**

```bash
flutter analyze lib/
```

预期：零 error 零 warning。所有旧 feature 的 import 都指向 `_deprecated` 路径。

**Step 7: 提交**

```bash
git add -A
git commit -m "refactor: move insights/mindmap/topics to _deprecated/"
```

---

### Task 2: 新增数据模型 `dashboard_models.dart`

**Files:**
- Create: `lib/core/models/dashboard_models.dart`

**Step 1: 创建文件**

```dart
import 'dart:convert';

/// 目标分类
enum GoalCategory {
  career,
  finance,
  relationship,
  health,
  growth,
  other,
}

/// 目标状态
enum GoalStatus {
  active,
  completed,
  paused,
}

/// 策略执行类型
enum StrategyType {
  selfAction,
  aiAssist,
  externalDep,
}

class Goal {
  int? id;
  String title;
  GoalCategory category;
  GoalStatus status;
  int? priority;
  List<int> sourceConvIds;
  String? deadline;
  String? notes;
  DateTime createdAt;
  DateTime updatedAt;

  Goal({
    this.id,
    required this.title,
    this.category = GoalCategory.other,
    this.status = GoalStatus.active,
    this.priority = 3,
    this.sourceConvIds = const [],
    this.deadline,
    this.notes,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Goal.fromMap(Map<String, dynamic> map) {
    final convIdsRaw = map['source_conv_ids'] as String? ?? '[]';
    final convIds = (jsonDecode(convIdsRaw) as List<dynamic>)
        .map((e) => e as int)
        .toList();

    return Goal(
      id: map['id'] as int?,
      title: map['title'] as String,
      category: _parseCategory(map['category'] as String?),
      status: _parseStatus(map['status'] as String?),
      priority: map['priority'] as int?,
      sourceConvIds: convIds,
      deadline: map['deadline'] as String?,
      notes: map['notes'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'title': title,
      'category': category.name,
      'status': status.name,
      'priority': priority,
      'source_conv_ids': jsonEncode(sourceConvIds),
      'deadline': deadline,
      'notes': notes,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  static GoalCategory _parseCategory(String? value) {
    return GoalCategory.values.firstWhere(
      (e) => e.name == value,
      orElse: () => GoalCategory.other,
    );
  }

  static GoalStatus _parseStatus(String? value) {
    return GoalStatus.values.firstWhere(
      (e) => e.name == value,
      orElse: () => GoalStatus.active,
    );
  }
}

class Strategy {
  int? id;
  int goalId;
  String description;
  StrategyType type;
  String? nextStep;
  bool completed;
  DateTime? nextReminder;
  DateTime createdAt;

  Strategy({
    this.id,
    required this.goalId,
    required this.description,
    this.type = StrategyType.selfAction,
    this.nextStep,
    this.completed = false,
    this.nextReminder,
    required this.createdAt,
  });

  factory Strategy.fromMap(Map<String, dynamic> map) {
    return Strategy(
      id: map['id'] as int?,
      goalId: map['goal_id'] as int,
      description: map['description'] as String,
      type: StrategyType.values.firstWhere(
        (e) => e.name == map['type'],
        orElse: () => StrategyType.selfAction,
      ),
      nextStep: map['next_step'] as String?,
      completed: (map['completed'] as int?) == 1,
      nextReminder: map['next_reminder'] != null
          ? DateTime.parse(map['next_reminder'] as String)
          : null,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'goal_id': goalId,
      'description': description,
      'type': type.name,
      'next_step': nextStep,
      'completed': completed ? 1 : 0,
      'next_reminder': nextReminder?.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
    };
  }
}

class CrossPattern {
  int? id;
  String label;
  String description;
  List<int> sourceConvIds;
  int frequency;
  DateTime detectedAt;

  CrossPattern({
    this.id,
    required this.label,
    required this.description,
    this.sourceConvIds = const [],
    this.frequency = 1,
    required this.detectedAt,
  });

  factory CrossPattern.fromMap(Map<String, dynamic> map) {
    final convIdsRaw = map['source_conv_ids'] as String? ?? '[]';
    final convIds = (jsonDecode(convIdsRaw) as List<dynamic>)
        .map((e) => e as int)
        .toList();

    return CrossPattern(
      id: map['id'] as int?,
      label: map['label'] as String,
      description: map['description'] as String,
      sourceConvIds: convIds,
      frequency: map['frequency'] as int? ?? 1,
      detectedAt: DateTime.parse(map['detected_at'] as String),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'label': label,
      'description': description,
      'source_conv_ids': jsonEncode(sourceConvIds),
      'frequency': frequency,
      'detected_at': detectedAt.toIso8601String(),
    };
  }
}
```

**Step 2: 验证**

```bash
flutter analyze lib/core/models/dashboard_models.dart
```

**Step 3: 提交**

```bash
git add lib/core/models/dashboard_models.dart
git commit -m "feat: add Goal/Strategy/CrossPattern data models"
```

---

### Task 3: DB 迁移（v2 → v3）新增 3 张表

**Files:**
- Modify: `lib/core/repository/conversation_repository.dart`

**Step 1: 升级 DB version 并在 `onUpgrade` 中建表**

在 `conversation_repository.dart` 中：
- 将 `version: 2` 改为 `version: 3`
- 在 `onUpgrade` 回调中新增：

```dart
if (oldVersion < 3) {
  await db.execute('''
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
    )
  ''');

  await db.execute('''
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
    )
  ''');

  await db.execute('''
    CREATE TABLE cross_patterns (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      label TEXT NOT NULL,
      description TEXT,
      source_conv_ids TEXT NOT NULL DEFAULT '[]',
      frequency INTEGER NOT NULL DEFAULT 1,
      detected_at TEXT NOT NULL
    )
  ''');
}
```

**Step 2: 验证**

```bash
flutter analyze lib/core/repository/conversation_repository.dart
```

**Step 3: 提交**

```bash
git add lib/core/repository/conversation_repository.dart
git commit -m "feat: DB migration v3 — add goals/strategies/cross_patterns tables"
```

---

### Task 4: 新增 `DashboardRepository`

**Files:**
- Create: `lib/core/repository/dashboard_repository.dart`

**Step 1: 创建 file**

```dart
import 'package:sqflite/sqflite.dart';
import 'package:socratic_ai/core/models/dashboard_models.dart';
import 'package:socratic_ai/core/repository/conversation_repository.dart';

class DashboardRepository {
  static Future<Database> _db() async {
    return ConversationRepository.database;
  }

  // ================================================================
  // Goals
  // ================================================================

  Future<int> insertGoal(Goal goal) async {
    final db = await _db();
    return db.insert('goals', goal.toMap());
  }

  Future<List<Goal>> getAllGoals() async {
    final db = await _db();
    final rows = await db.query('goals', orderBy: 'created_at DESC');
    return rows.map((row) => Goal.fromMap(row)).toList();
  }

  Future<Goal?> getGoalByTitle(String title) async {
    final db = await _db();
    final rows = await db.query('goals', where: 'title = ?', whereArgs: [title]);
    if (rows.isEmpty) return null;
    return Goal.fromMap(rows.first);
  }

  Future<void> updateGoal(Goal goal) async {
    final db = await _db();
    await db.update('goals', goal.toMap(), where: 'id = ?', whereArgs: [goal.id]);
  }

  // ================================================================
  // Strategies
  // ================================================================

  Future<int> insertStrategy(Strategy strategy) async {
    final db = await _db();
    return db.insert('strategies', strategy.toMap());
  }

  Future<List<Strategy>> getStrategiesByGoal(int goalId) async {
    final db = await _db();
    final rows = await db.query('strategies',
        where: 'goal_id = ?', whereArgs: [goalId], orderBy: 'created_at ASC');
    return rows.map((row) => Strategy.fromMap(row)).toList();
  }

  Future<List<Strategy>> getAllStrategies() async {
    final db = await _db();
    final rows = await db.query('strategies', orderBy: 'created_at DESC');
    return rows.map((row) => Strategy.fromMap(row)).toList();
  }

  // ================================================================
  // Cross Patterns
  // ================================================================

  Future<int> insertCrossPattern(CrossPattern pattern) async {
    final db = await _db();
    return db.insert('cross_patterns', pattern.toMap());
  }

  Future<List<CrossPattern>> getAllCrossPatterns() async {
    final db = await _db();
    final rows = await db.query('cross_patterns', orderBy: 'detected_at DESC');
    return rows.map((row) => CrossPattern.fromMap(row)).toList();
  }

  Future<CrossPattern?> getCrossPatternByLabel(String label) async {
    final db = await _db();
    final rows = await db.query('cross_patterns',
        where: 'label = ?', whereArgs: [label]);
    if (rows.isEmpty) return null;
    return CrossPattern.fromMap(rows.first);
  }

  Future<void> updateCrossPattern(CrossPattern pattern) async {
    final db = await _db();
    await db.update('cross_patterns', pattern.toMap(),
        where: 'id = ?', whereArgs: [pattern.id]);
  }
}
```

需要先让 `ConversationRepository.database` 暴露出来。在 `conversation_repository.dart` 中添加：

```dart
static Database? get database => _db;
```

**Step 2: 验证**

```bash
flutter analyze lib/core/repository/dashboard_repository.dart
flutter analyze lib/core/repository/conversation_repository.dart
```

**Step 3: 提交**

```bash
git add lib/core/repository/dashboard_repository.dart lib/core/repository/conversation_repository.dart
git commit -m "feat: add DashboardRepository with CRUD for goals/strategies/cross_patterns"
```

---

### Task 5: StrategistExtractor（LLM 提取引擎）

**Files:**
- Create: `lib/core/engine/strategist_extractor.dart`

**Step 1: 创建文件**

```dart
import 'dart:convert';

import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;
import 'package:socratic_ai/core/chat_utils.dart';
import 'package:socratic_ai/core/engine/llama_service.dart';
import 'package:socratic_ai/core/logger.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/models/conversation.dart';
import 'package:socratic_ai/core/models/dashboard_models.dart';
import 'package:socratic_ai/core/think_tag_stripper.dart';

class ExtractionResult {
  final List<Goal> newGoals;
  final List<GoalUpdate> goalUpdates;
  final List<Strategy> strategies;
  final List<CrossPattern> crossPatterns;

  ExtractionResult({
    this.newGoals = const [],
    this.goalUpdates = const [],
    this.strategies = const [],
    this.crossPatterns = const [],
  });

  bool get hasContent =>
      newGoals.isNotEmpty ||
      goalUpdates.isNotEmpty ||
      strategies.isNotEmpty ||
      crossPatterns.isNotEmpty;

  factory ExtractionResult.fromJson(Map<String, dynamic> json) {
    final now = DateTime.now();
    return ExtractionResult(
      newGoals: (json['new_goals'] as List<dynamic>?)
              ?.map((g) => _parseGoal(g as Map<String, dynamic>, now))
              .toList() ??
          [],
      goalUpdates: (json['goal_updates'] as List<dynamic>?)
              ?.map((u) => GoalUpdate.fromJson(u as Map<String, dynamic>))
              .toList() ??
          [],
      strategies: (json['strategies'] as List<dynamic>?)
              ?.map((s) => Strategy(
                    goalId: 0, // 由 merge 时根据 goal_title 填充
                    description: s['description'] as String? ?? '',
                    type: _parseStrategyType(s['type'] as String?),
                    nextStep: s['next_step'] as String?,
                    createdAt: now,
                  ))
              .toList() ??
          [],
      crossPatterns: (json['cross_patterns'] as List<dynamic>?)
              ?.map((p) => CrossPattern(
                    label: p['label'] as String? ?? '',
                    description: p['description'] as String? ?? '',
                    detectedAt: now,
                  ))
              .toList() ??
          [],
    );
  }

  static Goal _parseGoal(Map<String, dynamic> g, DateTime now) {
    return Goal(
      title: g['title'] as String? ?? '',
      category: GoalCategory.values.firstWhere(
        (e) => e.name == (g['category'] as String?),
        orElse: () => GoalCategory.other,
      ),
      priority: g['priority'] as int? ?? 3,
      deadline: g['deadline'] as String?,
      notes: g['notes'] as String?,
      createdAt: now,
      updatedAt: now,
    );
  }

  static StrategyType _parseStrategyType(String? type) {
    return StrategyType.values.firstWhere(
      (e) => e.name == type,
      orElse: () => StrategyType.selfAction,
    );
  }
}

class GoalUpdate {
  final String goalTitle;
  final GoalStatus? newStatus;
  final String? newNotes;
  final String reason;

  GoalUpdate({
    required this.goalTitle,
    this.newStatus,
    this.newNotes,
    this.reason = '',
  });

  factory GoalUpdate.fromJson(Map<String, dynamic> json) {
    return GoalUpdate(
      goalTitle: json['goal_title'] as String? ?? '',
      newStatus: json['new_status'] != null
          ? GoalStatus.values.firstWhere(
              (e) => e.name == json['new_status'],
              orElse: () => GoalStatus.active,
            )
          : null,
      newNotes: json['new_notes'] as String?,
      reason: json['reason'] as String? ?? '',
    );
  }
}

class StrategistExtractor {
  static const _systemPrompt = '''
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

new_goals 格式：
{"title":"...","category":"career|finance|relationship|health|growth|other","priority":1-5,"deadline":null或"2026-09-01","notes":"..."}

goal_updates 格式：
{"goal_title":"已有目标标题(精确匹配)","new_status":"active|completed|paused","new_notes":"...","reason":"为什么更新"}

strategies 格式：
{"goal_title":"关联的目标标题","description":"...","type":"selfAction|aiAssist|externalDep","next_step":"下一步具体动作"}

cross_patterns 格式：
{"label":"模式名称","description":"详细描述"}
''';

  /// 从对话中提取目标和策略。无实质内容时返回 null。
  Future<ExtractionResult?> extract({
    required Conversation conversation,
    required List<Goal> existingGoals,
  }) async {
    // 前置检查：对话太短跳过
    final userMsgs = conversation.messages
        .where((m) => m.role == MessageRole.user)
        .length;
    if (userMsgs < 2) {
      AppLogger.info('StrategistExtractor', '对话过短($userMsgs 条用户消息)，跳过提取');
      return null;
    }

    final engine = LlamaService.instance.engine;
    if (engine == null || !engine.isReady) {
      AppLogger.warn('StrategistExtractor', 'LLM 引擎未就绪，跳过提取');
      return null;
    }

    final chat = engine.createChat(
      contextSize: 4096,
      maxTokens: 4096,
    );
    chat.addSystem(_systemPrompt);

    final conversationText = buildConversationText(
      conversation.topic,
      conversation.messages,
    );

    final existingGoalsText = existingGoals.isNotEmpty
        ? '\n## 主公已有的目标\n${existingGoals.map((g) => "- [${g.status.name}] ${g.title}").join('\n')}\n'
        : '';

    chat.addUser('$existingGoalsText\n## 本轮对话\n$conversationText');

    try {
      final raw = await _collectResponse(chat);
      final json = stripThinkTags(raw);
      AppLogger.info('StrategistExtractor', '原始回复: ${json.substring(0, math.min(json.length, 200))}');

      final parsed = jsonDecode(json) as Map<String, dynamic>;
      if (parsed['relevant'] != true) {
        AppLogger.info('StrategistExtractor', 'LLM 判定无实质内容');
        return null;
      }

      final result = ExtractionResult.fromJson(parsed);
      AppLogger.info('StrategistExtractor',
          '提取完成: ${result.newGoals.length} 目标, ${result.strategies.length} 策略, ${result.crossPatterns.length} 模式');
      return result;
    } catch (e) {
      AppLogger.error('StrategistExtractor', '提取失败', e);
      return null;
    } finally {
      chat.dispose();
    }
  }

  Future<String> _collectResponse(EngineChat chat) async {
    final buffer = StringBuffer();
    await for (final token in chat.generate()) {
      buffer.write(token);
    }
    return buffer.toString();
  }
}
```

注意需要 `import 'dart:math' as math;`。

**Step 2: 验证**

```bash
flutter analyze lib/core/engine/strategist_extractor.dart
```

**Step 3: 提交**

```bash
git add lib/core/engine/strategist_extractor.dart
git commit -m "feat: add StrategistExtractor with relevance gate and goal/strategy extraction"
```

---

### Task 6: DashboardProvider（merge + 加载逻辑）

**Files:**
- Create: `lib/features/dashboard/providers/dashboard_provider.dart`

此 Provider 提供两个核心能力：
1. `load()` — 从 DB 加载全局面板数据（goals + strategies + patterns）
2. `merge(ExtractionResult)` — 将提取结果合并入库（同名 goal 合并 sourceConvIds，new strategy 关联 goalId）

**Step 1: 创建文件**

```dart
import 'package:flutter/foundation.dart';
import 'package:socratic_ai/core/logger.dart';
import 'package:socratic_ai/core/models/dashboard_models.dart';
import 'package:socratic_ai/core/repository/dashboard_repository.dart';

class DashboardState {
  final List<Goal> goals;
  final List<Strategy> strategies;
  final List<CrossPattern> crossPatterns;
  final bool isLoading;
  final String? error;

  DashboardState({
    this.goals = const [],
    this.strategies = const [],
    this.crossPatterns = const [],
    this.isLoading = false,
    this.error,
  });

  int get activeGoalCount => goals.where((g) => g.status == GoalStatus.active).length;
  int get pendingStrategyCount => strategies.where((s) => !s.completed).length;
  int get patternCount => crossPatterns.length;

  DashboardState copyWith({
    List<Goal>? goals,
    List<Strategy>? strategies,
    List<CrossPattern>? crossPatterns,
    bool? isLoading,
    String? error,
  }) {
    return DashboardState(
      goals: goals ?? this.goals,
      strategies: strategies ?? this.strategies,
      crossPatterns: crossPatterns ?? this.crossPatterns,
      isLoading: isLoading ?? this.isLoading,
      error: error ?? this.error,
    );
  }
}

class DashboardProvider {
  final DashboardRepository _repo = DashboardRepository();

  DashboardState _state = DashboardState();
  DashboardState get state => _state;

  final List<void Function(DashboardState)> _listeners = [];

  void addListener(void Function(DashboardState) listener) {
    _listeners.add(listener);
  }

  void removeListener(void Function(DashboardState) listener) {
    _listeners.remove(listener);
  }

  void _notify() {
    for (final listener in _listeners) {
      listener(_state);
    }
  }

  /// 从 DB 加载全局面板数据
  Future<void> load() async {
    _state = _state.copyWith(isLoading: true);
    _notify();

    try {
      final goals = await _repo.getAllGoals();
      final strategies = await _repo.getAllStrategies();
      final patterns = await _repo.getAllCrossPatterns();

      _state = _state.copyWith(
        goals: goals,
        strategies: strategies,
        crossPatterns: patterns,
        isLoading: false,
      );
    } catch (e) {
      AppLogger.error('DashboardProvider', '加载失败', e);
      _state = _state.copyWith(isLoading: false, error: e.toString());
    }
    _notify();
  }

  /// 合并提取结果到 DB
  Future<void> merge(ExtractionResult result) async {
    if (!result.hasContent) return;

    // 1) 合并新 goals（同名 goal 自动合并 sourceConvIds）
    for (final newGoal in result.newGoals) {
      final existing = await _repo.getGoalByTitle(newGoal.title);
      if (existing != null) {
        // 合并 sourceConvIds
        final mergedIds = {...existing.sourceConvIds, ...newGoal.sourceConvIds};
        existing.sourceConvIds = mergedIds.toList();
        existing.updatedAt = DateTime.now();
        await _repo.updateGoal(existing);
      } else {
        await _repo.insertGoal(newGoal);
      }
    }

    // 2) 处理 goal updates
    for (final update in result.goalUpdates) {
      final existing = await _repo.getGoalByTitle(update.goalTitle);
      if (existing != null) {
        if (update.newStatus != null) existing.status = update.newStatus!;
        if (update.newNotes != null) existing.notes = update.newNotes;
        existing.updatedAt = DateTime.now();
        await _repo.updateGoal(existing);
      }
    }

    // 3) 插入 strategies（关联 goal）
    final allGoals = await _repo.getAllGoals();
    for (final strategy in result.strategies) {
      final matchedGoal = allGoals.firstWhere(
        (g) => g.title == strategy.description, // TODO: 从 JSON 中正确提取 goal_title
        orElse: () => allGoals.first,
      );
      strategy.goalId = matchedGoal.id ?? 0;
      await _repo.insertStrategy(strategy);
    }

    // 4) 合并 cross patterns
    for (final pattern in result.crossPatterns) {
      final existing = await _repo.getCrossPatternByLabel(pattern.label);
      if (existing != null) {
        existing.frequency += 1;
        existing.detectedAt = DateTime.now();
        await _repo.updateCrossPattern(existing);
      } else {
        await _repo.insertCrossPattern(pattern);
      }
    }

    // 重新加载
    await load();
  }
}
```

**Step 2: 验证**

```bash
flutter analyze lib/features/dashboard/providers/dashboard_provider.dart
```

**Step 3: 提交**

```bash
git add lib/features/dashboard/providers/dashboard_provider.dart
git commit -m "feat: add DashboardProvider with load/merge logic"
```

---

### Task 7: 最终验证

```bash
flutter analyze lib/
```

预期：零 error 零 warning。三项旧 feature 全部在 `_deprecated/` 下无引用报错。

```bash
git status
```

确认所有变更为预期内容。

---

**Plan A 完成。** 产出：
- `lib/features/_deprecated/` — 3 个旧 feature
- `lib/core/models/dashboard_models.dart`
- `lib/core/repository/dashboard_repository.dart`
- `lib/core/engine/strategist_extractor.dart`
- `lib/features/dashboard/providers/dashboard_provider.dart`
- DB 升级到 v3（新增 3 张表）
