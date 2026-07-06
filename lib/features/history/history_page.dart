import 'package:flutter/material.dart';
import 'package:socratic_ai/core/theme.dart';

/// 历史对话列表页（当前为 stub 占位页）
///
/// Day 6 将被替换为完整的历史列表功能：
/// - 从后端拉取对话列表
/// - 对话卡片（话题 + 日期 + 核心洞察摘要）
/// - 点击进入洞察总结页（回溯查看）
/// - 左滑删除
class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('历史对话'),
        backgroundColor: AppTheme.background,
        surfaceTintColor: Colors.transparent,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.history, size: 48, color: AppTheme.textSecondary),
            const SizedBox(height: 16),
            Text(
              '历史对话',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '历史列表功能 Day 6 上线',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
