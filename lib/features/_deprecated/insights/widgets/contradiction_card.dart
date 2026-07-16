import 'package:flutter/material.dart';
import 'package:socratic_ai/core/theme.dart';

/// 认知矛盾卡片
///
/// 暖金色高亮背景 + 斜体文字，展示 LLM 发现的用户认知冲突。
class ContradictionCard extends StatelessWidget {
  /// 矛盾描述文本
  final String text;

  const ContradictionCard({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF8F0),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE8C89E)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text('⚡', style: TextStyle(fontSize: 16)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                  fontSize: 14,
                  color: AppTheme.textPrimary,
                  height: 1.5,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
