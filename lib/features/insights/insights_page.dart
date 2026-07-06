import 'package:flutter/material.dart';
import 'package:socratic_ai/core/models/chat_models.dart';

/// 洞察总结页面（当前为 stub 占位页）
///
/// 用户点击「结束对话」后跳转到此页面。
/// 接收已解析好的 [InsightResult]，不接触原始对话记录。
///
/// Day 4 将被替换为完整的洞察总结功能：
/// - 核心洞察卡片
/// - 价值观标签云
/// - 认知矛盾高亮
/// - 「查看思维图谱」和「开始新对话」按钮
class InsightsPage extends StatelessWidget {
  /// 已解析的对话洞察结果
  final InsightResult insight;

  /// 对话话题
  final String topic;

  const InsightsPage({
    super.key,
    required this.insight,
    required this.topic,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('对话洞察')),

      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '🔍',
              style: Theme.of(context).textTheme.displayMedium,
            ),
            const SizedBox(height: 16),
            Text(
              '「$topic」的对话洞察',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '核心洞察：${insight.coreInsights.length} 条',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '洞察总结功能 Day 4 上线',
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
