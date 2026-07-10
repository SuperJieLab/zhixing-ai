import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/models/conversation.dart';
import 'package:socratic_ai/core/repository/conversation_repository.dart';

/// 会话数据服务
///
/// 跨 feature 共享的会话数据访问层——chat、history、insights、mindmap
/// 都通过它读写会话。纯 Service，不持有 UI 状态，不继承 ChangeNotifier。
///
/// 调用方自行管理自己的状态（ChatPage 管 activeConversationId，
/// HistoryPage 管 conversations 列表和 loading/error）。
class ConversationService {
  final ConversationRepository _repo = ConversationRepository();

  // ================================================================
  // 生命周期
  // ================================================================

  /// 创建新会话，返回数据库 ID
  Future<int> createConversation(String topic) async {
    return _repo.create(topic: topic);
  }

  /// 保存消息到指定会话
  Future<void> saveMessages(int conversationId, List<ChatMessage> messages) async {
    await _repo.updateMessages(conversationId, messages);
  }

  /// 完成会话（写入洞察 + 标记 completed）
  Future<void> finishConversation(int conversationId, InsightResult? insight) async {
    await _repo.complete(conversationId, insight);
  }

  // ================================================================
  // 历史列表
  // ================================================================

  /// 加载所有会话
  Future<List<Conversation>> loadAll() async {
    return _repo.listAll();
  }

  /// 切换收藏状态
  Future<void> toggleFavorite(int id, bool currentValue) async {
    await _repo.toggleFavorite(id, currentValue);
  }

  /// 删除会话
  Future<void> deleteConversation(int id) async {
    await _repo.delete(id);
  }

  /// 保存图谱到指定会话
  Future<void> saveGraph(int conversationId, ConversationGraph graph) async {
    await _repo.saveGraph(conversationId, graph);
  }
}
