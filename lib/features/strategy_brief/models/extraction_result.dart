import 'package:zhixing_ai/core/data/models/dashboard_models.dart';

/// LLM 提取结果的数据模型
///
/// [ExtractionResult] 是一次对话提取的完整产物：
///   - newGoals：新发现的目标（proposed 状态，待确认）
///   - goalUpdates：已有目标的状态变更建议
///   - strategies：每个目标的执行步骤
///   - crossPatterns：跨对话自我认知模式
///
/// 支持 JSON 序列化（用于 extraction_json 缓存）和 DB 写入。

/// 容忍模型把 id 回传成字符串。
int? _parseIntOrNull(Object? value) {
  if (value is int) return value;
  if (value is String) return int.tryParse(value);
  return null;
}

class GoalUpdate {
  final String goalTitle;

  /// 关联的已有目标 id（提取契约 v2：LLM 从已有目标列表回传；旧缓存/未回传为 null）。
  final int? goalId;
  final GoalStatus? newStatus;
  final String? newNotes;
  final String reason;

  GoalUpdate({
    required this.goalTitle,
    this.goalId,
    this.newStatus,
    this.newNotes,
    this.reason = '',
  });

  factory GoalUpdate.fromJson(Map<String, dynamic> json) {
    final statusStr = json['suggested_status'] as String? ??
        json['new_status'] as String?;
    return GoalUpdate(
      goalTitle: json['goal_title'] as String? ?? '',
      goalId: _parseIntOrNull(json['goal_id']),
      newStatus: statusStr != null
          ? GoalStatus.values.firstWhere(
              (e) => e.name == statusStr,
              orElse: () => GoalStatus.active,
            )
          : null,
      newNotes: json['new_notes'] as String?,
      reason: json['reason'] as String? ?? '',
    );
  }
}

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
                    goalId: _parseIntOrNull(s['goal_id']) ?? 0,
                    description: s['description'] as String? ?? '',
                    type: _parseStrategyType(s['type'] as String?),
                    nextStep: s['next_step'] as String?,
                    goalTitle: s['goal_title'] as String?,
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

  Map<String, dynamic> toJson() {
    return {
      'new_goals': newGoals.map((g) => g.toMap()).toList(),
      'goal_updates': goalUpdates.map((u) => {
            if (u.goalId != null) 'goal_id': u.goalId,
            'goal_title': u.goalTitle,
            'suggested_status': u.newStatus?.name,
            'reason': u.reason,
          }).toList(),
      'strategies': strategies.map((s) => {
            ...s.toMap(),
            'goal_title': s.goalTitle,
          }).toList(),
      'cross_patterns': crossPatterns.map((p) => p.toMap()).toList(),
    };
  }

  static Goal _parseGoal(Map<String, dynamic> g, DateTime now) {
    return Goal(
      title: g['title'] as String? ?? '',
      category: GoalCategory.values.firstWhere(
        (e) => e.name == (g['category'] as String?),
        orElse: () => GoalCategory.other,
      ),
      status: GoalStatus.proposed,
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
