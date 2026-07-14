import 'package:socratic_ai/core/engine/llama_service.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/repository/conversation_repository.dart';
import 'package:socratic_ai/features/mindmap/engine/graph_service.dart';

/// 思维图谱状态管理
///
/// 职责：加载或生成 ConversationGraph。
/// 优先级：provider 内存缓存 > 外部 cachedGraph > LLM 生成。
/// 生成完成后自动持久化到 DB。
class MindMapProvider {
  final ConversationRepository _repo = ConversationRepository();

  bool _isLoading = false;
  String? _error;
  ConversationGraph? _graph;

  bool get isLoading => _isLoading;
  String? get error => _error;
  ConversationGraph? get graph => _graph;

  /// 加载或生成思维图谱
  Future<void> generateGraph({
    required String topic,
    required List<ChatMessage> messages,
    int? conversationId,
    ConversationGraph? cachedGraph,
  }) async {
    // 1) 内存缓存
    if (_graph != null && _graph!.isNotEmpty) return;

    // 2) 外部传入的缓存（如从 DB 读取）
    if (cachedGraph != null && cachedGraph.isNotEmpty) {
      _graph = cachedGraph;
      return;
    }

    // 3) LLM 生成
    _isLoading = true;
    _error = null;

    try {
      final engine = await LlamaService.instance.ensureReady();
      final service = GraphService(engine);
      _graph = await service.generate(topic, messages);

      // 持久化
      if (conversationId != null && _graph != null) {
        await _repo.saveGraph(conversationId, _graph!);
      }
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
    }
  }
}
