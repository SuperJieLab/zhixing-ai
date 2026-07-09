import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:socratic_ai/core/models/conversation.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/history/providers/conversation_provider.dart';
import 'package:socratic_ai/features/history/widgets/conversation_card.dart';
import 'package:socratic_ai/features/insights/insights_page.dart';

/// 历史对话列表页
///
/// 展示所有已完成/进行中的会话记录。
/// 支持查看洞察、收藏、删除。
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  @override
  void initState() {
    super.initState();
    // 首次加载时从数据库拉取
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ConversationProvider>().loadAll();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        surfaceTintColor: Colors.transparent,
        title: Consumer<ConversationProvider>(
          builder: (_, provider, _) {
            final count = provider.conversations.length;
            return Text(count > 0 ? '历史对话 ($count)' : '历史对话');
          },
        ),
      ),
      body: Consumer<ConversationProvider>(
        builder: (_, provider, _) {
          if (provider.isLoading) {
            return const Center(
              child: CircularProgressIndicator(color: AppTheme.primary),
            );
          }

          if (provider.hasError) {
            return _buildErrorView(provider);
          }

          if (provider.conversations.isEmpty) {
            return _buildEmptyState();
          }

          return ListView.separated(
            itemCount: provider.conversations.length,
            separatorBuilder: (_, _) => const SizedBox.shrink(),
            itemBuilder: (_, index) {
              final conv = provider.conversations[index];
              return ConversationCard(
                conversation: conv,
                onTap: () => _openInsight(conv),
                onFavoriteToggle: () => provider.toggleFavorite(conv.id!),
                onDelete: () => provider.deleteConversation(conv.id!),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.history, size: 48, color: AppTheme.textSecondary),
          const SizedBox(height: 16),
          Text(
            '还没有对话记录',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            '开始第一次探索吧',
            style: TextStyle(color: AppTheme.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorView(ConversationProvider provider) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.storage_outlined, size: 64, color: AppTheme.textSecondary),
            const SizedBox(height: 16),
            Text(
              provider.error ?? '加载失败',
              style: const TextStyle(fontSize: 16, color: AppTheme.textPrimary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => provider.retry(),
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  void _openInsight(Conversation conv) {
    if (conv.insight != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => InsightsPage(
            insight: conv.insight!,
            topic: conv.topic,
            messages: conv.messages,
            graph: conv.graph,
            conversationId: conv.id,
            fromHistory: true,
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该对话尚无洞察总结')),
      );
    }
  }
}
