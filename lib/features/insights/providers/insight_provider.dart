import 'package:flutter/material.dart';
import 'package:socratic_ai/core/engine/conversation_service.dart';
import 'package:socratic_ai/core/engine/llama_service.dart';
import 'package:socratic_ai/core/logger.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/features/insights/engine/insight_service.dart';
import 'package:socratic_ai/features/mindmap/engine/mindmap_service.dart';

/// 洞察页面状态管理
///
/// 唯一职责：管理 InsightsPage 的完整生命周期：
/// - 从对话生成洞察总结（generateInsights）
/// - 查看思维图谱（openMindMap）
/// - 洞察生成后自动持久化到 ConversationService
///
/// ## 分层
/// InsightProvider 是 page 和 engine 之间的接线层。
///
/// ## 两种使用模式
/// - 从 ChatPage 进入：调用 generateInsights() 从零生成
/// - 从 HistoryPage 进入：直接使用外部传入的 InsightResult，不生成
class InsightProvider extends ChangeNotifier {
  final ConversationService _conversationService;
  final MindMapService _mindMapService;

  bool _isLoading = false;
  String? _error;
  InsightResult? _insight;

  bool get isLoading => _isLoading;
  String? get error => _error;
  InsightResult? get insight => _insight;

  InsightProvider({
    ConversationService? conversationService,
    MindMapService? mindMapService,
  })  : _conversationService = conversationService ?? ConversationService(),
        _mindMapService = mindMapService ?? MindMapService();

  /// 从对话历史生成洞察总结
  ///
  /// 内部流程：获取 LLM 引擎 → InsightService.analyze() → 持久化。
  /// 引擎未就绪时生成兜底结果。
  Future<void> generateInsights({
    required String topic,
    required List<ChatMessage> messages,
    int? conversationId,
  }) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final engine = await LlamaService.instance.ensureReady();
      final service = InsightService(engine);
      final result = await service.analyze(topic, messages);

      _insight = result;

      // 持久化
      if (conversationId != null) {
        await _conversationService.finishConversation(
          conversationId,
          result.coreInsights.isNotEmpty ? result : null,
        );
      }
    } catch (e, stack) {
      AppLogger.error('InsightProvider', '洞察生成失败', e, stack);
      _error = e.toString();
      _insight = const InsightResult(
        coreInsights: ['对话分析完成'],
        underlyingValues: [],
        contradictionsFound: [],
      );
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

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
