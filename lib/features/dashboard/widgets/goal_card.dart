import 'package:flutter/material.dart';
import 'package:zhixing_ai/core/data/models/dashboard_models.dart';
import 'package:zhixing_ai/core/ui/theme.dart';

class GoalCard extends StatelessWidget {
  final Goal goal;
  final List<Strategy> strategies;
  final VoidCallback? onTap;
  final VoidCallback? onStatusTap;

  const GoalCard({
    super.key,
    required this.goal,
    this.strategies = const [],
    this.onTap,
    this.onStatusTap,
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
                        ],
                        if (onTap != null) ...[
                          const SizedBox(height: 4),
                          Align(
                            alignment: Alignment.centerRight,
                            child: Icon(Icons.chevron_right_rounded,
                                size: 18, color: AppTheme.textSecondary.withAlpha(120)),
                          ),
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
