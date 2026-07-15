import 'package:socratic_ai/core/engine/conversation_service.dart';
import 'package:socratic_ai/core/engine/llama_service.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/models/conversation.dart';
import 'package:socratic_ai/features/mindmap/engine/graph_service.dart';

/// 思维图谱状态管理
///
/// 职责：加载或生成 ConversationGraph。
/// 优先级：provider 内存缓存 > 外部 cachedGraph > LLM 生成。
/// 生成完成后自动持久化到 DB。
class MindMapProvider {
  final ConversationService _conversationService = ConversationService();

  bool _isLoading = false;
  String? _error;
  ConversationGraph? _graph;

  bool get isLoading => _isLoading;
  String? get error => _error;
  ConversationGraph? get graph => _graph;

  /// 加载或生成思维图谱
  ///
  /// 优先级：内存缓存 > conversation.graph > LLM 生成。
  /// 生成完成后自动持久化到 DB。
  Future<void> generateGraph({
    required Conversation conversation,
  }) async {
    // 1) 内存缓存
    if (_graph != null && _graph!.isNotEmpty) return;

    // 2) conversation 携带的缓存图谱
    if (conversation.graph != null && conversation.graph!.isNotEmpty) {
      _graph = conversation.graph;
      return;
    }

    // 3) LLM 生成
    _isLoading = true;
    _error = null;

    try {
      final engine = await LlamaService.instance.ensureReady();
      final service = GraphService(engine);
      _graph = await service.generate(conversation.topic, conversation.messages);

      // 持久化
      if (conversation.id != null && _graph != null) {
        await _conversationService.saveGraph(conversation.id!, _graph!);
      }
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
    }
  }
}
