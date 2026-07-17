import 'package:flutter/foundation.dart';

import 'package:socratic_ai/core/engine/conversation_service.dart';
import 'package:socratic_ai/core/engine/llama_service.dart';
import 'package:socratic_ai/core/logger.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/models/conversation.dart';
import 'package:socratic_ai/core/repository/dashboard_repository.dart';
import 'package:socratic_ai/features/chat/engine/strategist_prompter.dart';

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

  StrategistPrompter? _engine;
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
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  // ================================================================
  // 持久化
  // ================================================================

  int? _activeConversationId;

  int? get activeConversationId => _activeConversationId;
  ConversationService get conversationService => _conversationService;

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
    _engine?.dispose();
    super.dispose();
  }

  // ================================================================
  // 欢迎语
  // ================================================================

  static List<ChatMessage> _buildWelcome(String topic) {
    final opening = topic.isNotEmpty
        ? '主公提到想聊聊$topic——请详细说说你的想法，我来帮你分析。'
        : '主公请讲，军师在此。有任何困惑或打算，尽管说来——我帮你看清局势，给出策略。';

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
      final engine = StrategistPrompter(llmEngine);

      final dashboardRepo = DashboardRepository();
      final activeGoals = await dashboardRepo.getActiveGoals();

      await engine.initialize(existingGoals: activeGoals);
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

    // Seed the engine with current history before adding new messages.
    // At this point _messages contains only what the engine hasn't seen yet.
    if (!_engineSeeded && _engine != null) {
      _engineSeeded = true;
      _engine!.seedHistory(_messages);
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
