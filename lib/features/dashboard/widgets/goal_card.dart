import 'package:flutter/material.dart';
import 'package:socratic_ai/core/models/dashboard_models.dart';
import 'package:socratic_ai/core/theme.dart';

class GoalCard extends StatelessWidget {
  final Goal goal;
  final List<Strategy> strategies;
  final VoidCallback? onTap;

  const GoalCard({
    super.key,
    required this.goal,
    this.strategies = const [],
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final statusIcon = _statusIcon(goal.status);
    final categoryLabel = _categoryLabel(goal.category);

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(statusIcon.icon, size: 18, color: statusIcon.color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(goal.title,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w500)),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withAlpha(20),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(categoryLabel,
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.primary)),
                  ),
                ],
              ),
              if (goal.sourceConvIds.length > 1) ...[
                const SizedBox(height: 4),
                Text('来源: ${goal.sourceConvIds.length} 次对话',
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary)),
              ],
              if (strategies.isNotEmpty) ...[
                const SizedBox(height: 8),
                const Divider(height: 1),
                const SizedBox(height: 8),
                ...strategies.map((s) => _StrategyRow(strategy: s)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static ({IconData icon, Color color}) _statusIcon(GoalStatus status) {
    switch (status) {
      case GoalStatus.active:
        return (icon: Icons.circle, color: AppTheme.primary);
      case GoalStatus.completed:
        return (icon: Icons.check_circle, color: Colors.green);
      case GoalStatus.paused:
        return (icon: Icons.pause_circle, color: AppTheme.textSecondary);
    }
  }

  static String _categoryLabel(GoalCategory category) {
    switch (category) {
      case GoalCategory.career:
        return '职业';
      case GoalCategory.finance:
        return '财务';
      case GoalCategory.relationship:
        return '人际';
      case GoalCategory.health:
        return '健康';
      case GoalCategory.growth:
        return '成长';
      case GoalCategory.other:
        return '其他';
    }
  }
}

class _StrategyRow extends StatelessWidget {
  final Strategy strategy;

  const _StrategyRow({required this.strategy});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            strategy.completed
                ? Icons.check_box
                : Icons.check_box_outline_blank,
            size: 18,
            color:
                strategy.completed ? AppTheme.textSecondary : AppTheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(strategy.description,
                style: TextStyle(
                    fontSize: 13,
                    color: strategy.completed
                        ? AppTheme.textSecondary
                        : AppTheme.textPrimary)),
          ),
        ],
      ),
    );
  }
}
