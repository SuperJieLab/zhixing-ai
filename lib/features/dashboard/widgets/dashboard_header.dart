import 'package:flutter/material.dart';
import 'package:zhixing_ai/core/theme.dart';

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
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          colors: [Color(0xFFF8F6F2), Color(0xFFF0EDE6)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: const Color(0xFFE8E4DD), width: 1),
      ),
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 4),
      child: Row(
        children: [
          _StatItem(
            icon: Icons.flag_rounded,
            label: '活跃目标',
            value: '$activeGoalCount',
            color: AppTheme.primary,
          ),
          const _Divider(),
          _StatItem(
            icon: Icons.task_alt_rounded,
            label: '待执行',
            value: '$pendingStrategyCount',
            color: AppTheme.accent,
          ),
          const _Divider(),
          _StatItem(
            icon: Icons.lightbulb_rounded,
            label: '洞察',
            value: '$patternCount',
            color: AppTheme.secondary,
          ),
        ],
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _StatItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: color.withAlpha(180)),
          const SizedBox(height: 6),
          Text(value,
              style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: color)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 12)),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      width: 1,
      color: const Color(0xFFDDD9D2),
    );
  }
}
