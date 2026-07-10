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
///
/// ## 设计决策
/// 不继承 ChangeNotifier，因为当前 InsightProvider 自身没有需要
/// Page 响应式监听的状态——加载中/错误等都由 MindMapService 内的
/// Dialog/SnackBar 直接处理。
class InsightProvider {
  final MindMapService _mindMapService = MindMapService();

  /// 打开思维图谱
  ///
  /// 参数透传给 [MindMapService.openMindMap]。
  Future<void> openMindMap(
    BuildContext context, {
    required String topic,
    required List<ChatMessage> messages,
    int? conversationId,
    ConversationGraph? cachedGraph,
  }) {
    return _mindMapService.openMindMap(
      context,
      topic: topic,
      messages: messages,
      conversationId: conversationId,
      cachedGraph: cachedGraph,
    );
  }
}
