import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/chat/chat_page.dart';
import 'package:socratic_ai/features/history/providers/history_provider.dart';
import 'package:socratic_ai/features/history/widgets/conversation_card.dart';
import 'package:socratic_ai/features/strategy_brief/strategy_brief_page.dart';

/// 历史对话列表页
///
/// 展示所有已完成/进行中的会话记录。
/// 通过 [HistoryProvider] 管理状态（Provider → ConversationService → Repository）。
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => HistoryProvider()..loadAll(),
      child: Consumer<HistoryProvider>(
        builder: (_, provider, _) {
          return Scaffold(
            backgroundColor: AppTheme.background,
            appBar: AppBar(
              backgroundColor: AppTheme.background,
              surfaceTintColor: Colors.transparent,
              title: Text(
                provider.conversations.isNotEmpty
                    ? '历史对话 (${provider.conversations.length})'
                    : '历史对话',
              ),
            ),
            body: _buildBody(provider),
          );
        },
      ),
    );
  }

  Widget _buildBody(HistoryProvider provider) {
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
          onTap: () {
            if (conv.status == 'completed') {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => StrategyBriefPage(conversation: conv),
                ),
              );
            } else {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ChatPage(
                    topic: conv.topic,
                    conversation: conv,
                  ),
                ),
              ).then((_) => provider.loadAll());
            }
          },
          onFavoriteToggle: () => provider.toggleFavorite(conv.id!, conv.isFavorite),
          onDelete: () => provider.deleteConversation(conv.id!),
        );
      },
    );
  }

  Widget _buildErrorView(HistoryProvider provider) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.storage_outlined, size: 64, color: AppTheme.error),
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

}
