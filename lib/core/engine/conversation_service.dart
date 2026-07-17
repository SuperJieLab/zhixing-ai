import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/models/conversation.dart';
import 'package:socratic_ai/core/repository/conversation_repository.dart';

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

  Future<Conversation?> loadConversation(int id) async {
    if (_cache.containsKey(id)) return _cache[id];
    final conv = await _repo.getById(id);
    if (conv != null) _cache[id] = conv;
    return conv;
  }

  Future<List<Conversation>> loadAll() async {
    final list = await _repo.listAll();
    for (final conv in list) {
      if (conv.id != null) {
        _cache.putIfAbsent(conv.id!, () => conv);
      }
    }
    return list;
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
