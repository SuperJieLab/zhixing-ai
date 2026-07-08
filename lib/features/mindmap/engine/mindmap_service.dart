import 'package:flutter/material.dart';
import 'package:socratic_ai/core/engine/llama_service.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/history/engine/conversation_repository.dart';
import 'package:socratic_ai/features/mindmap/engine/graph_service.dart';
import 'package:socratic_ai/features/mindmap/mindmap_page.dart';

/// 思维图谱服务
///
/// 封装图谱的打开、生成、缓存、持久化等全部逻辑。
/// 调用方只需传 [topic] + [messages] + 可选的 [conversationId] + [cachedGraph]。
class MindMapService {
  final ConversationRepository _repo = ConversationRepository();

  MindMapService();

  // ================================================================
  // 对外接口
  // ================================================================

  /// 打开思维图谱，返回最终使用的图谱（供调用方缓存）。
  ///
  /// 命中缓存 → 直接导航，返回缓存数据。
  /// 未命中   → LLM 生成 + 自动持久化 + 导航，返回新生成的数据。
  Future<ConversationGraph?> openMindMap(
    BuildContext context, {
    required String topic,
    required List<ChatMessage> messages,
    int? conversationId,
    ConversationGraph? cachedGraph,
  }) async {
    // 命中缓存 → 直接打开
    if (cachedGraph != null && cachedGraph.isNotEmpty) {
      _navigate(context, topic, cachedGraph);
      return cachedGraph;
    }

    // 无缓存 → 生成 + 持久化 + 打开
    _showLoading(context);
    try {
      final graph = await _generate(topic, messages);

      // 自动保存到数据库
      if (conversationId != null) {
        await _repo.saveGraph(conversationId, graph);
      }

      if (!context.mounted) return null;
      _dismissLoading(context);
      if (!context.mounted) return null;
      _navigate(context, topic, graph);
      return graph;
    } catch (e) {
      if (context.mounted) _dismissLoading(context);
      if (context.mounted) _showError(context, e);
      return null;
    }
  }

  // ================================================================
  // 私有
  // ================================================================

  Future<ConversationGraph> _generate(
    String topic,
    List<ChatMessage> messages,
  ) async {
    final engine = await LlamaService.instance.ensureReady();
    final service = GraphService(engine);
    return await service.generate(topic, messages);
  }

  void _showLoading(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: AppTheme.primary),
                SizedBox(height: 16),
                Text('正在生成思维图谱...'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _dismissLoading(BuildContext context) {
    Navigator.of(context, rootNavigator: true).pop();
  }

  void _showError(BuildContext context, Object e) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('图谱生成失败: $e')),
    );
  }

  void _navigate(BuildContext context, String topic, ConversationGraph graph) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MindMapPage(graph: graph, topic: topic),
      ),
    );
  }
}
