import 'package:flutter/foundation.dart';

import 'package:socratic_ai/core/engine/conversation_service.dart';
import 'package:socratic_ai/core/engine/llama_service.dart';
import 'package:socratic_ai/core/logger.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/models/conversation.dart';
import 'package:socratic_ai/features/insights/engine/insight_service.dart';

/// 洞察页面状态管理
///
/// 唯一职责：加载或生成 InsightResult。
/// 优先级：conversation.insight > conversationId 查 DB > LLM 生成。
class InsightProvider extends ChangeNotifier {
  final ConversationService _conversationService;

  bool _isLoading = false;
  String? _error;
  InsightResult? _insight;

  bool get isLoading => _isLoading;
  String? get error => _error;
  InsightResult? get insight => _insight;

  InsightProvider({
    ConversationService? conversationService,
  }) : _conversationService = conversationService ?? ConversationService();

  /// 加载或生成洞察总结
  ///
  /// 优先级：conversation.insight > 通过 conversationId 查 DB > LLM 生成。
  /// ChatPage 传 conversationId，HistoryPage 传 conversation。
  Future<void> generateInsights({
    required String topic,
    required List<ChatMessage> messages,
    int? conversationId,
    Conversation? conversation,
  }) async {
    // 1) 传入的 conversation 已有洞察 → 直接使用
    if (conversation?.insight != null) {
      _insight = conversation!.insight;
      notifyListeners();
      return;
    }

    // 2) 通过 conversationId 查 DB（路径 1 未命中时，例如 ChatPage）
    final lookupId = conversationId ?? conversation?.id;
    if (lookupId != null) {
      final conv = await _conversationService.loadConversation(lookupId);
      if (conv?.insight != null) {
        _insight = conv!.insight;
        notifyListeners();
        return;
      }
    }

    // 无缓存 → 调用 LLM 生成
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final engine = await LlamaService.instance.ensureReady();
      final service = InsightService(engine);
      final result = await service.analyze(topic, messages);

      _insight = result;

      // 持久化
      if (lookupId != null) {
        await _conversationService.finishConversation(
          lookupId,
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
}
