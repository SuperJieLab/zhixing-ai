import 'package:flutter/material.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/theme.dart';

/// 节点详情底部弹窗
///
/// 点击图谱节点时展示，显示：
/// - 节点标签和分类
/// - 关联节点列表（含关系标签）
class NodeDetailSheet extends StatelessWidget {
  final GraphNode node;
  final List<GraphEdge> edges;
  final List<GraphNode> allNodes;

  const NodeDetailSheet({
    super.key,
    required this.node,
    required this.edges,
    required this.allNodes,
  });

  @override
  Widget build(BuildContext context) {
    final relatedEdges = edges
        .where((e) => e.source == node.id || e.target == node.id)
        .toList();

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 拖拽指示条
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFD0C8C0),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          // 节点标签
          Text(
            node.label,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          // 分类标签
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: _typeColor(node.type).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              _typeLabel(node.type),
              style: TextStyle(
                fontSize: 12,
                color: _typeColor(node.type),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          // 关联节点
          if (relatedEdges.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              '关联概念',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            ...relatedEdges.map((edge) {
              final otherId =
                  edge.source == node.id ? edge.target : edge.source;
              final otherNode = allNodes
                  .cast<GraphNode?>()
                  .firstWhere((n) => n?.id == otherId, orElse: () => null);
              if (otherNode == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Icon(Icons.arrow_forward,
                        size: 14, color: _typeColor(otherNode.type)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        otherNode.label,
                        style: const TextStyle(
                          fontSize: 14,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                    ),
                    if (edge.label.isNotEmpty)
                      Text(
                        '(${edge.label})',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Color _typeColor(String type) {
    switch (type) {
      case 'topic':
        return AppTheme.primary;
      case 'insight':
        return const Color(0xFF5B8D8D);
      case 'value':
        return AppTheme.secondary;
      case 'action':
        return AppTheme.accent;
      case 'contradiction':
        return const Color(0xFFD4735B);
      default:
        return AppTheme.primary;
    }
  }

  String _typeLabel(String type) {
    switch (type) {
      case 'topic':
        return '话题';
      case 'insight':
        return '洞察';
      case 'value':
        return '价值观';
      case 'action':
        return '行动';
      case 'contradiction':
        return '矛盾';
      default:
        return '';
    }
  }
}
