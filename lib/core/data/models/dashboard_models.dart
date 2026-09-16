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
  proposed,
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
  DateTime createdAt;

  /// 提取期携带的目标标题（`strategies` 表不落此列）：提取结果里目标尚无
  /// 自增 id，`_insertStrategiesForGoal` 靠它把策略归属到刚确认的目标。
  String? goalTitle;

  Strategy({
    this.id,
    required this.goalId,
    required this.description,
    this.type = StrategyType.selfAction,
    this.nextStep,
    this.completed = false,
    required this.createdAt,
    this.goalTitle,
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
