import 'package:zhixing_ai/core/models/chat_models.dart';
import 'package:zhixing_ai/core/models/conversation.dart';
import 'package:zhixing_ai/core/repository/conversation_repository.dart';

/// 会话数据服务（带 Identity Map 缓存）
///
/// 同一 conversationId 在内存中只有一个 Conversation 实例。
/// 所有 mutation 同时更新内存缓存和 DB。
class ConversationService {
  final ConversationRepository _repo = ConversationRepository();

  /// 全局共享缓存：同一 conversationId 返回同一个 Conversation 对象
  static final Map<int, Conversation> _cache = {};

  // ================================================================
  // 获取
  // ================================================================

  /// 加载全部会话列表
  ///
  /// 返回的是缓存实例，已缓存的会话对象在内存中就地被 DB 数据更新。
  /// 这样 ChatProvider / BriefPage 持有的同一引用也能看到最新 DB 状态。
  Future<List<Conversation>> loadAll() async {
    final list = await _repo.listAll();
    for (final conv in list) {
      if (conv.id == null) continue;
      final cached = _cache[conv.id];
      if (cached != null) {
        // Update cached instance in-place (preserve in-memory messages)
        cached.status = conv.status;
        cached.topic = conv.topic;
        cached.extractionJson = conv.extractionJson;
      } else {
        _cache[conv.id!] = conv;
      }
    }
    // Return cached instances so all consumers share the same objects
    return list.map((c) => _cache[c.id] ?? c).toList();
  }

  void cacheConversation(Conversation conversation) {
    if (conversation.id != null) {
      _cache[conversation.id!] = conversation;
    }
  }

  // ================================================================
  // Mutation
  // ================================================================

  Future<int> createConversation(String topic) async {
    return _repo.create(topic: topic);
  }

  Future<void> saveMessages(
      int conversationId, List<ChatMessage> messages) async {
    final cached = _cache[conversationId];
    if (cached != null) cached.messages = messages;
    await _repo.updateMessages(conversationId, messages);
  }

  Future<void> finishConversation(int conversationId) async {
    final cached = _cache[conversationId];
    if (cached != null) cached.status = 'completed';
    await _repo.markCompleted(conversationId);
  }

  Future<void> updateTopic(int conversationId, String topic) async {
    final cached = _cache[conversationId];
    if (cached != null) cached.topic = topic;
    await _repo.updateTopic(conversationId, topic);
  }

  Future<void> updateExtractionJson(
      int conversationId, String extractionJson) async {
    final cached = _cache[conversationId];
    if (cached != null) cached.extractionJson = extractionJson;
    await _repo.updateExtractionJson(conversationId, extractionJson);
  }

  Future<void> toggleFavorite(int id, bool currentValue) async {
    await _repo.toggleFavorite(id, currentValue);
  }

  Future<void> deleteConversation(int id) async {
    _cache.remove(id);
    await _repo.delete(id);
  }
}
