import 'package:flutter/material.dart';
import 'package:socratic_ai/core/models/dashboard_models.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/dashboard/widgets/goal_card.dart';

class GoalDetailPage extends StatelessWidget {
  final Goal goal;
  final List<Strategy> strategies;
  final void Function(Strategy) onStrategyToggle;

  const GoalDetailPage({
    super.key,
    required this.goal,
    required this.strategies,
    required this.onStrategyToggle,
  });

  @override
  Widget build(BuildContext context) {
    final catColor = GoalCard.categoryColor(goal.category);
    final completedCount = strategies.where((s) => s.completed).length;
    final progress =
        strategies.isEmpty ? 0.0 : completedCount / strategies.length;

    return Scaffold(
      appBar: AppBar(
        title: Text(goal.title),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Goal info header
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: catColor.withAlpha(12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: catColor.withAlpha(30), width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: catColor.withAlpha(30),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(_categoryLabel(goal.category),
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: catColor)),
                    ),
                    const SizedBox(width: 8),
                    if (goal.deadline != null)
                      Text('截止: ${goal.deadline}',
                          style: const TextStyle(
                              fontSize: 11,
                              color: AppTheme.textSecondary)),
                  ],
                ),
                const SizedBox(height: 8),
                if (goal.notes != null && goal.notes!.isNotEmpty) ...[
                  Text(goal.notes!,
                      style: const TextStyle(
                          fontSize: 13,
                          color: AppTheme.textSecondary,
                          height: 1.4)),
                  const SizedBox(height: 8),
                ],
                if (strategies.isNotEmpty) ...[
                  Row(
                    children: [
                      Text('$completedCount / ${strategies.length} 已完成',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: catColor)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: progress,
                            backgroundColor: catColor.withAlpha(25),
                            valueColor:
                                AlwaysStoppedAnimation<Color>(catColor),
                            minHeight: 4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),

          if (strategies.isNotEmpty) ...[
            const SizedBox(height: 20),
            const Text('执行策略',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            ...strategies.map((s) => _buildStrategyCard(s, catColor)),
          ],

          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildStrategyCard(Strategy strategy, Color catColor) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => onStrategyToggle(strategy),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                strategy.completed
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked,
                size: 20,
                color: strategy.completed
                    ? catColor.withAlpha(120)
                    : catColor,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(strategy.description,
                        style: TextStyle(
                            fontSize: 14,
                            height: 1.4,
                            color: strategy.completed
                                ? AppTheme.textSecondary.withAlpha(180)
                                : AppTheme.textPrimary,
                            decoration: strategy.completed
                                ? TextDecoration.lineThrough
                                : null)),
                    if (strategy.nextStep != null &&
                        strategy.nextStep!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text('下一步: ${strategy.nextStep}',
                          style: const TextStyle(
                              fontSize: 12,
                              color: AppTheme.textSecondary)),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
