import 'package:flutter/material.dart';
import 'package:socratic_ai/core/models/dashboard_models.dart';
import 'package:socratic_ai/core/theme.dart';

class CrossPatternCard extends StatelessWidget {
  final CrossPattern pattern;

  const CrossPatternCard({super.key, required this.pattern});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFFAF6EF),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE6DDCE), width: 1),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppTheme.accent.withAlpha(30),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.lightbulb_rounded, size: 18, color: AppTheme.accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(pattern.label,
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w600, height: 1.3)),
                        ),
                        if (pattern.frequency > 1)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppTheme.accent.withAlpha(25),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text('${pattern.frequency}次',
                                style: const TextStyle(fontSize: 10, color: AppTheme.accent)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(pattern.description,
                        style: const TextStyle(
                            fontSize: 13, color: AppTheme.textSecondary, height: 1.4)),
                    if (pattern.sourceConvIds.length > 1) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(Icons.chat_bubble_outline_rounded,
                              size: 11, color: AppTheme.textSecondary.withAlpha(140)),
                          const SizedBox(width: 3),
                          Text('跨 ${pattern.sourceConvIds.length} 次对话发现',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: AppTheme.textSecondary.withAlpha(160))),
                        ],
                      ),
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
}
