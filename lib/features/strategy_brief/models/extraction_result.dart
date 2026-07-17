import 'package:socratic_ai/core/models/dashboard_models.dart';

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
    final statusStr = json['suggested_status'] as String? ??
        json['new_status'] as String?;
    return GoalUpdate(
      goalTitle: json['goal_title'] as String? ?? '',
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
                    goalId: 0,
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
