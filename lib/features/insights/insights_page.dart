import 'package:flutter/material.dart';
import 'package:socratic_ai/features/chat/providers/chat_provider.dart';

/// 洞察总结页面（当前为 stub 占位页）
///
/// 用户点击「结束对话」后跳转到此页面。
/// Day 4 中将被替换为完整的洞察总结功能：
/// - 核心洞察提取
/// - 价值观标签
/// - 发现的认知矛盾
class InsightsPage extends StatelessWidget {
  /// 完整的对话记录
  final List<ChatMessage> conversation;

  /// 对话话题
  final String topic;

  const InsightsPage({
    super.key,
    required this.conversation,
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
              '共 ${conversation.length} 条消息',
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
