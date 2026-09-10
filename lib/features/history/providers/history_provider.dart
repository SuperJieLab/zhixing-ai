import 'package:flutter/foundation.dart';
import 'package:zhixing_ai/core/data/conversation_service.dart';
import 'package:zhixing_ai/core/logger.dart';
import 'package:zhixing_ai/core/data/models/conversation.dart';

/// History 页面状态管理
///
/// 管理历史对话列表的加载、收藏、删除等状态。
/// 通过 [ConversationService] 访问数据层，页面上通过 Consumer 监听。
///
/// ## 分层
/// HistoryProvider 是 HistoryPage 的专属状态管理层，
/// 不跨 feature 共享（跨 feature 的数据访问走 ConversationService）。
class HistoryProvider extends ChangeNotifier {
  final ConversationService _conversationService;

  HistoryProvider({ConversationService? conversationService})
      : _conversationService = conversationService ?? ConversationService();

  List<Conversation> _conversations = [];
  bool _isLoading = false;
  String? _error;

  List<Conversation> get conversations => _conversations;
  bool get isLoading => _isLoading;
  bool get hasError => _error != null && _conversations.isEmpty;
  String? get error => _error;

  /// 加载历史对话列表
  Future<void> loadAll() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _conversations = await _conversationService.loadAll();
    } catch (e) {
      AppLogger.error('HistoryProvider', '加载失败', e);
      _error = '无法加载对话记录，请检查存储空间后重试';
      _conversations = [];
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 重试加载
  Future<void> retry() async {
    await loadAll();
  }

  /// 切换收藏
  Future<void> toggleFavorite(int id, bool currentValue) async {
    try {
      await _conversationService.toggleFavorite(id, currentValue);
      final index = _conversations.indexWhere((c) => c.id == id);
      if (index != -1) {
        _conversations[index] = _conversations[index].copyWith(isFavorite: !currentValue);
        notifyListeners();
      }
    } catch (e) {
      AppLogger.error('HistoryProvider', '切换收藏失败', e);
    }
  }

  /// 删除对话
  Future<void> deleteConversation(int id) async {
    try {
      await _conversationService.deleteConversation(id);
      _conversations.removeWhere((c) => c.id == id);
      notifyListeners();
    } catch (e) {
      AppLogger.error('HistoryProvider', '删除失败', e);
    }
  }
}
