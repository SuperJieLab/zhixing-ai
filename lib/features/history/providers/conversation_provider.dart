import 'package:flutter/foundation.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/models/conversation.dart';
import 'package:socratic_ai/features/history/engine/conversation_repository.dart';

/// 历史会话状态管理
///
/// 同时管理两个职责：
/// - **活跃会话生命周期**：startConversation / saveMessages / finishConversation
/// - **历史列表**：loadAll / toggleFavorite / deleteConversation
///
/// ChatPage 只依赖此 Provider，不直接接触 Repository。
class ConversationProvider extends ChangeNotifier {
  final ConversationRepository _repo = ConversationRepository();

  // ================================================================
  // 活跃会话（ChatPage 正在进行的对话）
  // ================================================================

  int? _activeConversationId;

  /// 是否有活跃会话
  bool get hasActiveConversation => _activeConversationId != null;

  /// 当前活跃会话的数据库 ID（null 表示没有活跃会话）
  int? get activeConversationId => _activeConversationId;

  /// 开始一个新会话（入库 + 返回 id）
  Future<int> startConversation(String topic) async {
    final id = await _repo.create(topic: topic);
    _activeConversationId = id;
    return id;
  }

  /// 保存当前活跃会话的消息列表
  Future<void> saveMessages(List<ChatMessage> messages) async {
    if (_activeConversationId == null) return;
    await _repo.updateMessages(_activeConversationId!, messages);
  }

  /// 完成活跃会话（写入洞察 + 标记 completed）
  Future<void> finishConversation(InsightResult? insight) async {
    if (_activeConversationId == null) return;
    await _repo.complete(_activeConversationId!, insight);
    _activeConversationId = null;
  }

  // ================================================================
  // 历史列表
  // ================================================================

  List<Conversation> _conversations = [];
  bool _isLoading = false;

  String? _error;
  String? get error => _error;
  bool get hasError => _error != null;

  List<Conversation> get conversations => _conversations;
  bool get isLoading => _isLoading;

  /// 从数据库加载所有会话
  Future<void> loadAll() async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      _conversations = await _repo.listAll();
    } catch (e) {
      debugPrint('[ConversationProvider] 加载失败: $e');
      _error = '无法加载对话记录，请检查存储空间后重试';
      _conversations = [];
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 重试加载历史记录
  Future<void> retry() async {
    await loadAll();
  }

  /// 切换收藏状态
  Future<void> toggleFavorite(int id) async {
    final index = _conversations.indexWhere((c) => c.id == id);
    if (index == -1) return;

    final conv = _conversations[index];
    await _repo.toggleFavorite(id, conv.isFavorite);
    _conversations[index] = conv.copyWith(isFavorite: !conv.isFavorite);
    notifyListeners();
  }

  /// 删除会话
  Future<void> deleteConversation(int id) async {
    try {
      await _repo.delete(id);
      _conversations.removeWhere((c) => c.id == id);
      notifyListeners();
    } catch (e) {
      debugPrint('[ConversationProvider] 删除失败: $e');
      _error = '操作失败，请重试';
      notifyListeners();
    }
  }
}
