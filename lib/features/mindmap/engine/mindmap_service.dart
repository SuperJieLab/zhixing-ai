import 'package:flutter/material.dart';
import 'package:socratic_ai/core/engine/llama_service.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/snackbar_throttle.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/core/repository/conversation_repository.dart';
import 'package:socratic_ai/features/mindmap/engine/graph_service.dart';
import 'package:socratic_ai/features/mindmap/mindmap_page.dart';

/// 思维图谱服务
///
/// 封装图谱的打开、生成、缓存、持久化等全部逻辑。
/// 调用方只需保持同一个实例，每次调 [openMindMap] 即可。
class MindMapService {
  final ConversationRepository _repo = ConversationRepository();

  /// 内部缓存（生成一次后复用，避免重复 LLM 调用）
  ConversationGraph? _graph;

  MindMapService();

  // ================================================================
  // 对外接口
  // ================================================================

  /// 打开思维图谱
  ///
  /// 内部缓存优先，其次 [cachedGraph]（来自 DB），否则走 LLM 生成。
  /// [conversationId] 非 null 时，生成的图谱会自动保存到数据库。
  Future<void> openMindMap(
    BuildContext context, {
    required String topic,
    required List<ChatMessage> messages,
    int? conversationId,
    ConversationGraph? cachedGraph,
  }) async {
    // 内部缓存命中
    if (_graph != null && _graph!.isNotEmpty) {
      _navigate(context, topic, _graph!);
      return;
    }

    // 外部传入的缓存（如从 DB 读取的）
    if (cachedGraph != null && cachedGraph.isNotEmpty) {
      _graph = cachedGraph;
      _navigate(context, topic, cachedGraph);
      return;
    }

    // 无缓存 → 生成 + 持久化 + 缓存 + 打开
    _showLoading(context);
    try {
      final graph = await _generate(topic, messages);

      // 自动保存到数据库
      if (conversationId != null) {
        await _repo.saveGraph(conversationId, graph);
      }

      _graph = graph;

      if (!context.mounted) return;
      _dismissLoading(context);
      if (!context.mounted) return;
      _navigate(context, topic, graph);
    } catch (e) {
      if (context.mounted) _dismissLoading(context);
      if (context.mounted) _showError(context, e);
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
    SnackBarThrottle.show(context, '图谱生成失败: $e');
  }

  void _navigate(BuildContext context, String topic, ConversationGraph graph) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MindMapPage(graph: graph, topic: topic),
      ),
    );
  }
}
