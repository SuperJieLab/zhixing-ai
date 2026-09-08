import 'package:flutter/foundation.dart';

import 'package:zhixing_ai/core/engine/conversation_service.dart';
import 'package:zhixing_ai/core/engine/llama_service.dart';
import 'package:zhixing_ai/core/logger.dart';
import 'package:zhixing_ai/core/models/chat_models.dart';
import 'package:zhixing_ai/core/models/conversation.dart';
import 'package:zhixing_ai/core/repository/dashboard_repository.dart';
import 'package:zhixing_ai/core/repository/settings_repository.dart';
import 'package:zhixing_ai/features/chat/engine/cloud_chat_client.dart';
import 'package:zhixing_ai/features/chat/engine/strategist_prompter.dart';

/// 对话状态管理
///
/// 管理一次助手对话的完整生命周期：
///   1. 加载模型 → [loadModel] 初始化 [StrategistPrompter] 并注入已有目标
///   2. 对话交互 → [sendMessage] 驱动 LLM 流式生成回复
///   3. 持久化 → 每轮保存 messages 到 DB，通过 [ConversationService]
///   4. 结束 → ChatPage 调用 _endConversation，跳转 Brief 页
///
/// ## 两种模式
/// - 新对话：只传 [topic]，Provider 内部加欢迎语，首次发言时创建 DB 记录
/// - 恢复：传 [conversation]，Provider 加载其消息 / ID / 轮次，引擎回放历史
///
/// 两种模式在 sendMessage 内部统一为：首次使用引擎时 seedHistory。
class ChatProvider extends ChangeNotifier {
  final String _topic;
  final ConversationService _conversationService;
  final ChatMode _mode;

  // 云端模式复用的 SSE 客户端（本地模式不会真正发起请求）。
  final CloudChatClient _cloud = CloudChatClient();

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
    this._mode = ChatMode.local,
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
    _cloud.dispose();
    super.dispose();
  }

  // ================================================================
  // 欢迎语
  // ================================================================

  static List<ChatMessage> _buildWelcome(String topic) {
    final opening = topic.isNotEmpty
        ? '用户提到想聊聊$topic——请详细说说你的想法，我来帮你分析。'
        : '用户请讲，助手在此。有任何困惑或打算，尽管说来——我帮你看清局势，给出策略。';

    return [ChatMessage(role: MessageRole.ai, content: opening, round: 0)];
  }

  // ================================================================
  // 引擎初始化
  // ================================================================

  Future<void> loadModel() async {
    _isModelLoading = true;
    notifyListeners();

    try {
      final llmEngine = await LlamaService.instance
          .ensureReady(gpuLayers: SettingsRepository.instance.gpuLayers);
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
    // 云端模式不需要：历史由 _sendCloud 显式构造并随请求发送。
    if (_mode != ChatMode.cloud && !_engineSeeded && _engine != null) {
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
      if (_mode == ChatMode.cloud) {
        await _sendCloud(content, aiMessageIndex);
      } else {
        await _sendLocal(content, aiMessageIndex);
      }
    } catch (e, stack) {
      AppLogger.error('ChatProvider', '推理失败', e, stack);
      if (_mode == ChatMode.cloud &&
          _messages[aiMessageIndex].content.isEmpty) {
        // 云端完全无产出：降级为本地 Mock 回复，给出友好提示。
        AppLogger.warn('ChatProvider', '云端失败，降级为本地回复');
        _error = '云端连接失败，已使用本地回复';
        _messages[aiMessageIndex] = ChatMessage(
          role: MessageRole.ai,
          content: _generateMockResponse(),
          round: _round,
        );
      } else if (_messages[aiMessageIndex].content.isEmpty) {
        // 本地引擎失败（含未就绪兜底之外的异常）：保留通用失败文案。
        _error = e.toString();
        _messages[aiMessageIndex] = ChatMessage(
          role: MessageRole.ai,
          content: '抱歉，我在思考时遇到了一些问题。你能换个方式再说说吗？',
          round: _round,
        );
      } else {
        // 云端已流出部分内容：保留半成品，仅记录错误。
        _error = e.toString();
      }
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

  /// 本地引擎流式生成（原 sendMessage 内联逻辑提取）
  Future<void> _sendLocal(String content, int aiMessageIndex) async {
    final engine = _engine;

    if (engine == null || !engine.isReady) {
      _messages[aiMessageIndex] = ChatMessage(
        role: MessageRole.ai,
        content: _generateMockResponse(),
        round: _round,
      );
      return;
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

  /// 云端 SSE 流式生成
  ///
  /// 历史窗口：取 [content] 对应的用户消息追加前的最后 10 条消息（过滤 round==0
  /// 欢迎语，因其读起来像助手指令而非真实对话），映射角色后附上本轮用户消息发送。
  /// 注意：调用此方法时用户消息与空 AI 占位符已入 [_messages]（末尾 2 条），
  /// 需剔除后再取窗口，否则用户消息会重复下发、占位符会变成空 assistant 轮。
  Future<void> _sendCloud(String content, int aiMessageIndex) async {
    var window = _messages
        .sublist(0, _messages.length - 2)
        .where((m) => m.round != 0)
        .toList();
    if (window.length > 10) {
      window = window.sublist(window.length - 10);
    }

    final cloudMessages = window
        .map((m) => (
              role: m.role == MessageRole.user ? 'user' : 'assistant',
              content: m.content,
            ))
        .toList();
    cloudMessages.add((role: 'user', content: content));

    final buffer = StringBuffer();
    await for (final delta in _cloud.generateResponse(cloudMessages)) {
      buffer.write(delta);
      _messages[aiMessageIndex] = ChatMessage(
        role: MessageRole.ai,
        content: buffer.toString(),
        round: _round,
      );
      notifyListeners();
    }
  }

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
