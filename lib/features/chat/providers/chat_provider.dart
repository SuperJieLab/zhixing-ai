import 'package:flutter/foundation.dart';

import '../../../core/engine/conversation_service.dart';
import '../../../core/engine/dialogue_engine.dart';
import '../../../core/engine/llama_service.dart';
import '../../../core/logger.dart';
import '../../../core/models/chat_models.dart';
import '../../../core/models/conversation.dart';
import '../engine/socratic_prompter.dart';

/// 对话状态管理
///
/// ## 两种模式
/// - 新对话：只传 [topic]，Provider 内部加欢迎语，首次发言时创建 DB 记录
/// - 恢复：传 [conversation]，Provider 加载其消息 / ID / 轮次，引擎回放历史
///
/// 两种模式在 sendMessage 内部统一为：首次使用引擎时 seedHistory。
class ChatProvider extends ChangeNotifier {
  final String _topic;
  final ConversationService _conversationService;

  // ================================================================
  // 引擎状态
  // ================================================================

  DialogueEngine? _engine;
  bool _isModelLoading = false;
  String? _modelError;

  bool get isModelReady => _engine != null && _engine!.isReady;
  bool get isModelLoading => _isModelLoading;
  String? get modelError => _modelError;
  bool get hasModelError => _modelError != null;

  // ================================================================
  // 对话状态
  // ================================================================

  int _round;
  bool _isThinking = false;
  String? _error;
  final List<ChatMessage> _messages;
  bool _engineSeeded = false;

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  int get round => _round;
  bool get isThinking => _isThinking;
  String? get error => _error;

  void clearError() {
    _error = null;
  }

  // ================================================================
  // 持久化
  // ================================================================

  int? _activeConversationId;

  int? get activeConversationId => _activeConversationId;

  Future<void> startConversation() async {
    _activeConversationId = await _conversationService.createConversation(_topic);
  }

  // ================================================================
  // 生命周期
  // ================================================================

  ChatProvider({
    required String topic,
    Conversation? conversation,
    ConversationService? conversationService,
  })  : _topic = topic,
        _messages = conversation?.messages ?? _buildWelcome(topic),
        _round = conversation != null
            ? conversation.messages
                    .where((m) => m.role == MessageRole.user)
                    .length +
                1
            : 1,
        _activeConversationId = conversation?.id,
        _conversationService = conversationService ?? ConversationService();

  @override
  void dispose() {
    if (_engine is SocraticPrompter) {
      (_engine as SocraticPrompter).dispose();
    }
    super.dispose();
  }

  // ================================================================
  // 欢迎语
  // ================================================================

  static List<ChatMessage> _buildWelcome(String topic) {
    const openings = <String, String>{
      '职业发展':
          '你提到想聊聊职业方向——如果三年后的你回头看今天做的选择，你觉得他会在意什么？',
      '两难决策':
          '你面前有两个选择——在做决定之前，你想过这两个选择分别代表了什么样的自己吗？',
      '自我探索':
          '关于"我是谁"这个问题——你最近一次觉得自己不够了解自己，是什么时候？',
      '工作难题':
          '这个问题卡住了你——你觉得卡住的到底是事情本身，还是你看待事情的角度？',
      '人际关系':
          '这段关系让你在意的地方是什么——是对方的期待，还是你对自己在这段关系里的要求？',
    };

    final opening = openings[topic] ?? '你想和我聊聊什么话题？让我们从头开始。';

    return [ChatMessage(role: MessageRole.ai, content: opening, round: 0)];
  }

  // ================================================================
  // 引擎初始化
  // ================================================================

  Future<void> loadModel() async {
    _isModelLoading = true;
    notifyListeners();

    try {
      final llmEngine = await LlamaService.instance.ensureReady();
      final engine = SocraticPrompter(llmEngine);
      await engine.initialize();
      _engine = engine;
    } catch (e) {
      AppLogger.warn('ChatProvider', '模型加载失败，将使用 Mock 回复: $e');
      _modelError = e.toString();
    } finally {
      _isModelLoading = false;
      notifyListeners();
    }
  }

  Future<void> retryLoadModel() async {
    _modelError = null;
    await loadModel();
  }

  // ================================================================
  // 对话
  // ================================================================

  Future<void> sendMessage(String content) async {
    if (_activeConversationId == null) {
      await startConversation();
    }

    _messages.add(ChatMessage(
      role: MessageRole.user,
      content: content,
      round: _round,
    ));

    _isThinking = true;
    notifyListeners();

    final aiMessageIndex = _messages.length;
    _messages.add(ChatMessage(
      role: MessageRole.ai,
      content: '',
      round: _round,
    ));

    try {
      final engine = _engine;

      if (engine == null || !engine.isReady) {
        _messages[aiMessageIndex] = ChatMessage(
          role: MessageRole.ai,
          content: _generateMockResponse(),
          round: _round,
        );
      } else {
        if (!_engineSeeded && engine is SocraticPrompter) {
          _engineSeeded = true;
          engine.seedHistory(_messages.sublist(0, _messages.length - 2));
        }

        final buffer = StringBuffer();
        await for (final token in engine.generateResponse(content)) {
          buffer.write(token);
          _messages[aiMessageIndex] = ChatMessage(
            role: MessageRole.ai,
            content: buffer.toString(),
            round: _round,
          );
          notifyListeners();
        }
      }
    } catch (e, stack) {
      AppLogger.error('ChatProvider', '推理失败', e, stack);
      _error = e.toString();
      _messages[aiMessageIndex] = ChatMessage(
        role: MessageRole.ai,
        content: '抱歉，我在思考时遇到了一些问题。你能换个方式再说说吗？',
        round: _round,
      );
    } finally {
      _round++;
      _isThinking = false;
      notifyListeners();
      _saveMessages();
    }
  }

  // ================================================================
  // 私有
  // ================================================================

  void _saveMessages() {
    if (_activeConversationId == null) return;
    _conversationService.saveMessages(_activeConversationId!, _messages);
  }

  String _generateMockResponse() {
    const responses = [
      '你提到的这点很有意思——你能给我一个具体的例子吗？',
      '如果完全没有失败的风险，你的答案会变吗？',
      '你刚才说到的这个想法，背后最让你担心的是什么？',
      '换句话说，你觉得这件事对你来说最重要的是什么？',
      '如果一位朋友处在你的位置，你给他什么建议？',
    ];

    return responses[_messages.length % responses.length];
  }
}
