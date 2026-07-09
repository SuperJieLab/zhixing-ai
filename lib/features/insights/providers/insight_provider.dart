import 'package:flutter/material.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/features/mindmap/engine/mindmap_service.dart';

/// 洞察页面状态管理
///
/// 唯一职责：承接 InsightsPage 的「查看思维图谱」交互。
/// 内部委托 [MindMapService] 处理图谱生成、缓存、持久化、导航。
///
/// ## 分层
/// InsightProvider 是 page 和 engine 之间的接线层：
/// page → 只看到 provider 和 model，不会直接引用 engine 层的 MindMapService。
class InsightProvider extends ChangeNotifier {
  final MindMapService _mindMapService = MindMapService();

  bool _isGenerating = false;

  /// 是否正在生成图谱
  bool get isGenerating => _isGenerating;

  /// 打开思维图谱
  ///
  /// 参数透传给 [MindMapService.openMindMap]。
  Future<void> openMindMap(
    BuildContext context, {
    required String topic,
    required List<ChatMessage> messages,
    int? conversationId,
    ConversationGraph? cachedGraph,
  }) async {
    _isGenerating = true;
    notifyListeners();

    await _mindMapService.openMindMap(
      context,
      topic: topic,
      messages: messages,
      conversationId: conversationId,
      cachedGraph: cachedGraph,
    );

    _isGenerating = false;
    notifyListeners();
  }
}
