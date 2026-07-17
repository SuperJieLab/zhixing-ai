import 'package:flutter/material.dart';
import 'package:socratic_ai/core/models/dashboard_models.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/dashboard/widgets/goal_card.dart';

class StrategyTimeline extends StatelessWidget {
  final List<Strategy> strategies;
  final Map<int, Goal> goalMap;

  const StrategyTimeline({
    super.key,
    required this.strategies,
    required this.goalMap,
  });

  @override
  Widget build(BuildContext context) {
    final pending = strategies.where((s) {
      if (s.completed) return false;
      final goal = goalMap[s.goalId];
      if (goal == null) return false;
      return goal.status == GoalStatus.active;
    }).toList();

    // Sort: higher goal priority first, then by creation time
    pending.sort((a, b) {
      final goalA = goalMap[a.goalId];
      final goalB = goalMap[b.goalId];
      final priorityDiff =
          (goalB?.priority ?? 3).compareTo(goalA?.priority ?? 3);
      if (priorityDiff != 0) return priorityDiff;
      return a.createdAt.compareTo(b.createdAt);
    });

    if (pending.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: List.generate(pending.length, (i) {
        final strategy = pending[i];
        final goal = goalMap[strategy.goalId];
        final catColor = goal != null ? GoalCard.categoryColor(goal.category) : AppTheme.primary;
        final isLast = i == pending.length - 1;

        return _TimelineItem(
          strategy: strategy,
          goal: goal,
          catColor: catColor,
          isLast: isLast,
        );
      }),
    );
  }
}

class _TimelineItem extends StatelessWidget {
  final Strategy strategy;
  final Goal? goal;
  final Color catColor;
  final bool isLast;

  const _TimelineItem({
    required this.strategy,
    required this.goal,
    required this.catColor,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 28,
            child: Column(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  margin: const EdgeInsets.only(top: 4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: catColor.withAlpha(180),
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 1.5,
                      color: const Color(0xFFE0DCD4),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(strategy.description,
                      style: const TextStyle(
                          fontSize: 13, height: 1.4, color: AppTheme.textPrimary)),
                  if (goal != null) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: catColor.withAlpha(15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(goal!.title,
                              style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w500,
                                  color: catColor)),
                        ),
                        if (strategy.type == StrategyType.aiAssist) ...[
                          const SizedBox(width: 4),
                          Icon(Icons.auto_awesome_rounded,
                              size: 12,
                              color: AppTheme.textSecondary.withAlpha(150)),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
