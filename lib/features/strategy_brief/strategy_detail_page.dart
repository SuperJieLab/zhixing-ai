import 'package:flutter/material.dart';
import 'package:socratic_ai/core/models/dashboard_models.dart';
import 'package:socratic_ai/core/theme.dart';

class StrategyDetailPage extends StatelessWidget {
  final Goal goal;
  final List<Strategy> strategies;

  const StrategyDetailPage({
    super.key,
    required this.goal,
    required this.strategies,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(goal.title),
      ),
      body: strategies.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.inbox_outlined,
                      size: 48, color: AppTheme.textSecondary),
                  const SizedBox(height: 12),
                  const Text('暂无策略',
                      style: TextStyle(
                          fontSize: 15, color: AppTheme.textSecondary)),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (goal.notes != null && goal.notes!.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withAlpha(10),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.info_outline,
                            size: 16, color: AppTheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(goal.notes!,
                              style: const TextStyle(
                                  fontSize: 13,
                                  color: AppTheme.textSecondary,
                                  height: 1.4)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                const Text('执行策略',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                ...strategies.map((s) => Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              s.completed
                                  ? Icons.check_circle_rounded
                                  : Icons.radio_button_unchecked,
                              size: 20,
                              color: s.completed
                                  ? AppTheme.primary.withAlpha(120)
                                  : AppTheme.primary,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(s.description,
                                      style: TextStyle(
                                          fontSize: 14,
                                          height: 1.4,
                                          color: s.completed
                                              ? AppTheme.textSecondary
                                                  .withAlpha(180)
                                              : AppTheme.textPrimary)),
                                  if (s.nextStep != null &&
                                      s.nextStep!.isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        const Icon(Icons.arrow_forward,
                                            size: 12,
                                            color: AppTheme.textSecondary),
                                        const SizedBox(width: 4),
                                        Text('下一步: ${s.nextStep}',
                                            style: const TextStyle(
                                                fontSize: 12,
                                                color:
                                                    AppTheme.textSecondary)),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    )),
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}
