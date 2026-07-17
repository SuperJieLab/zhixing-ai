import 'package:flutter/material.dart';
import 'package:socratic_ai/core/models/dashboard_models.dart';
import 'package:socratic_ai/core/theme.dart';

class GoalCard extends StatelessWidget {
  final Goal goal;
  final List<Strategy> strategies;
  final VoidCallback? onTap;
  final VoidCallback? onStatusTap;
  final void Function(Strategy)? onStrategyToggle;

  const GoalCard({
    super.key,
    required this.goal,
    this.strategies = const [],
    this.onTap,
    this.onStatusTap,
    this.onStrategyToggle,
  });

  static Color categoryColor(GoalCategory category) {
    switch (category) {
      case GoalCategory.career:
        return AppTheme.primary;
      case GoalCategory.finance:
        return AppTheme.accent;
      case GoalCategory.relationship:
        return const Color(0xFFD4838A);
      case GoalCategory.health:
        return const Color(0xFF5EA3A0);
      case GoalCategory.growth:
        return AppTheme.secondary;
      case GoalCategory.other:
        return const Color(0xFF9E9E9E);
    }
  }

  static IconData _categoryIcon(GoalCategory category) {
    switch (category) {
      case GoalCategory.career:
        return Icons.work_rounded;
      case GoalCategory.finance:
        return Icons.savings_rounded;
      case GoalCategory.relationship:
        return Icons.people_rounded;
      case GoalCategory.health:
        return Icons.favorite_rounded;
      case GoalCategory.growth:
        return Icons.auto_awesome_rounded;
      case GoalCategory.other:
        return Icons.more_horiz_rounded;
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

  @override
  Widget build(BuildContext context) {
    final catColor = categoryColor(goal.category);
    final completedCount = strategies.where((s) => s.completed).length;
    final progress = strategies.isEmpty ? 0.0 : completedCount / strategies.length;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 4, color: catColor),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildHeader(catColor),
                        if (goal.sourceConvIds.length > 1) ...[
                          const SizedBox(height: 6),
                          _buildSourceInfo(),
                        ],
                        if (strategies.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          _buildProgressBar(catColor, progress, completedCount),
                          const SizedBox(height: 8),
                          ...strategies.map((s) => _StrategyRow(
                                strategy: s,
                                catColor: catColor,
                                onToggle: onStrategyToggle != null
                                    ? () => onStrategyToggle!(s)
                                    : null,
                              )),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(Color catColor) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: catColor.withAlpha(20),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_categoryIcon(goal.category), size: 14, color: catColor),
              const SizedBox(width: 4),
              Text(_categoryLabel(goal.category),
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: catColor)),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(goal.title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, height: 1.3)),
        ),
      ],
    );
  }

  Widget _buildSourceInfo() {
    return Row(
      children: [
        Icon(Icons.auto_stories_rounded, size: 13, color: AppTheme.textSecondary.withAlpha(150)),
        const SizedBox(width: 4),
        Text('来自 ${goal.sourceConvIds.length} 次对话',
            style: TextStyle(fontSize: 11, color: AppTheme.textSecondary.withAlpha(180))),
      ],
    );
  }

  Widget _buildProgressBar(Color catColor, double progress, int completedCount) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('策略进度',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: AppTheme.textSecondary.withAlpha(200))),
            const Spacer(),
            Text('$completedCount/${strategies.length}',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: catColor)),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: progress,
            backgroundColor: catColor.withAlpha(25),
            valueColor: AlwaysStoppedAnimation<Color>(catColor),
            minHeight: 4,
          ),
        ),
      ],
    );
  }
}

class _StrategyRow extends StatelessWidget {
  final Strategy strategy;
  final Color catColor;
  final VoidCallback? onToggle;

  const _StrategyRow({
    required this.strategy,
    required this.catColor,
    this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onToggle,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                strategy.completed ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
                size: 16,
                color: strategy.completed ? catColor.withAlpha(120) : catColor.withAlpha(180),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(strategy.description,
                  style: TextStyle(
                      fontSize: 13,
                      height: 1.35,
                      color: strategy.completed
                          ? AppTheme.textSecondary.withAlpha(180)
                          : AppTheme.textPrimary.withAlpha(220),
                      decoration: strategy.completed ? TextDecoration.lineThrough : null)),
            ),
          ],
        ),
      ),
    );
  }
}
