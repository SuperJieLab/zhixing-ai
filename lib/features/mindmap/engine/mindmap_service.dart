import 'package:flutter/material.dart';
import 'package:socratic_ai/core/engine/llama_service.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/mindmap/engine/graph_service.dart';
import 'package:socratic_ai/features/mindmap/mindmap_page.dart';

/// 思维图谱状态管理
///
/// 封装图谱的生成、loading、错误处理、导航等全部逻辑。
/// InsightsPage 只需调 [openMindMap]，不需要知道底层细节。
class MindMapService {
  MindMapService();

  // ================================================================
  // 对外接口
  // ================================================================

  /// 一键生成图谱并打开
  ///
  /// 处理 loading 弹窗、LLM 生成、错误提示、导航跳转的全部流程。
  /// [messages] 对话消息列表。
  Future<void> openMindMap(
    BuildContext context,
    String topic,
    List<ChatMessage> messages,
  ) async {
    _showLoading(context);
    try {
      final graph = await _generate(topic, messages);
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
    try {
      final engine = await LlamaService.instance.ensureReady();
      final service = GraphService(engine);
      return await service.generate(topic, messages);
    } catch (e) {
      debugPrint('[MindMapService] 获取引擎失败: $e');
      return const ConversationGraph();
    }
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
