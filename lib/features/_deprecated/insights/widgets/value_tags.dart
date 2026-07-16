import 'package:flutter/material.dart';
import 'package:socratic_ai/core/theme.dart';

/// 价值观标签云
///
/// 以暖棕色 Chip 样式展示 LLM 提取的底层价值观关键词。
class ValueTags extends StatelessWidget {
  /// 价值观关键词列表
  final List<String> values;

  const ValueTags({super.key, required this.values});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: values.map((v) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFE0D9D1)),
          ),
          child: Text(
            v,
            style: const TextStyle(
              fontSize: 13,
              color: AppTheme.secondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        );
      }).toList(),
    );
  }
}
