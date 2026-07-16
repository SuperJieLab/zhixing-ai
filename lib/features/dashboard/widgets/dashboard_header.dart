import 'package:flutter/material.dart';
import 'package:socratic_ai/core/theme.dart';

class DashboardHeader extends StatelessWidget {
  final int activeGoalCount;
  final int pendingStrategyCount;
  final int patternCount;

  const DashboardHeader({
    super.key,
    required this.activeGoalCount,
    required this.pendingStrategyCount,
    required this.patternCount,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _StatItem(label: '活跃目标', value: '$activeGoalCount'),
          _StatItem(label: '待执行', value: '$pendingStrategyCount'),
          _StatItem(label: '发现', value: '$patternCount'),
        ],
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final String label;
  final String value;

  const _StatItem({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style: const TextStyle(
                fontSize: 28, fontWeight: FontWeight.bold, color: AppTheme.primary)),
        const SizedBox(height: 4),
        Text(label,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
      ],
    );
  }
}
