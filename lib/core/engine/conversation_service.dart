import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/models/conversation.dart';
import 'package:socratic_ai/core/repository/conversation_repository.dart';

/// 会话数据服务（带 Identity Map 缓存）
///
/// 同一 conversationId 在内存中只有一个 Conversation 实例。
/// 所有 mutation（saveGraph / finishConversation / saveMessages / delete）
/// 同时更新内存缓存和 DB，确保页面间传递的 Conversation 始终一致。
class ConversationService {
  final ConversationRepository _repo = ConversationRepository();

  /// 全局共享缓存：同一 conversationId 所有 ConversationService 实例
  /// 返回同一个 Conversation 对象。
  static final Map<int, Conversation> _cache = {};

  // ================================================================
  // 获取
  // ================================================================

  /// 按 id 获取会话（缓存优先，miss 时查 DB）
  Future<Conversation?> loadConversation(int id) async {
    if (_cache.containsKey(id)) return _cache[id];
    final conv = await _repo.getById(id);
    if (conv != null) _cache[id] = conv;
    return conv;
  }

  /// 加载所有会话（同时也填充缓存）
  Future<List<Conversation>> loadAll() async {
    final list = await _repo.listAll();
    for (final conv in list) {
      if (conv.id != null) {
        _cache.putIfAbsent(conv.id!, () => conv);
      }
    }
    return list;
  }

  /// 将外部构造的 Conversation 注册到缓存
  ///
  /// ChatPage._endConversation 等场景会自行构造 Conversation，
  /// 调用此方法后，后续 mutation 会更新此实例的字段。
  void cacheConversation(Conversation conversation) {
    if (conversation.id != null) {
      _cache[conversation.id!] = conversation;
    }
  }

  // ================================================================
  // Mutation（同时更新缓存 + DB）
  // ================================================================

  /// 创建新会话，返回数据库 ID
  Future<int> createConversation(String topic) async {
    return _repo.create(topic: topic);
  }

  /// 保存消息
  Future<void> saveMessages(int conversationId, List<ChatMessage> messages) async {
    final cached = _cache[conversationId];
    if (cached != null) cached.messages = messages;
    await _repo.updateMessages(conversationId, messages);
  }

  /// 完成会话（写入洞察 + 标记 completed）
  Future<void> finishConversation(int conversationId, InsightResult? insight) async {
    final cached = _cache[conversationId];
    if (cached != null) {
      cached.status = 'completed';
      if (insight != null) cached.insight = insight;
    }
    await _repo.complete(conversationId, insight);
  }

  /// 保存图谱
  Future<void> saveGraph(int conversationId, ConversationGraph graph) async {
    final cached = _cache[conversationId];
    if (cached != null) cached.graph = graph;
    await _repo.saveGraph(conversationId, graph);
  }

  /// 切换收藏状态
  Future<void> toggleFavorite(int id, bool currentValue) async {
    await _repo.toggleFavorite(id, currentValue);
  }

  /// 删除会话（同时从缓存移除）
  Future<void> deleteConversation(int id) async {
    _cache.remove(id);
    await _repo.delete(id);
  }
}
