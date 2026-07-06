import 'package:flutter/material.dart';
import 'package:socratic_ai/core/models/conversation.dart';
import 'package:socratic_ai/core/theme.dart';

/// 历史对话卡片
///
/// 展示话题标题、轮次数、相对时间、洞察摘要。
/// 右侧收藏星标，支持左滑删除回调。
class ConversationCard extends StatelessWidget {
  final Conversation conversation;
  final VoidCallback onTap;
  final VoidCallback onFavoriteToggle;
  final VoidCallback onDelete;

  const ConversationCard({
    super.key,
    required this.conversation,
    required this.onTap,
    required this.onFavoriteToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final conv = conversation;
    final firstInsight =
        conv.hasInsight && conv.insight!.coreInsights.isNotEmpty
            ? conv.insight!.coreInsights.first
            : null;

    return Dismissible(
      key: Key('conversation_${conv.id}'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async {
        return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('删除对话'),
            content: Text('确定删除「${conv.topic}」的对话记录吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child:
                    const Text('删除', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        );
      },
      onDismissed: (_) => onDelete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: Colors.red.shade50,
        child: const Icon(Icons.delete_outline, color: Colors.red),
      ),
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Color(0xFFE8E4DF), width: 0.5),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      conv.topic,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${conv.totalRounds} 轮对话 · ${_formatTime(conv.updatedAt)}',
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    if (conv.hasInsight && firstInsight != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        firstInsight,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppTheme.primary,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              GestureDetector(
                onTap: onFavoriteToggle,
                child: Icon(
                  conv.isFavorite ? Icons.star : Icons.star_border,
                  color: conv.isFavorite
                      ? AppTheme.accent
                      : AppTheme.textSecondary,
                  size: 22,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    return '${dt.month}/${dt.day}';
  }
}
