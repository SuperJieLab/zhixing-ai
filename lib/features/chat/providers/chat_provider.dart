import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:zhixing_ai/core/data/conversation_service.dart';
import 'package:zhixing_ai/core/llm/llama_service.dart';
import 'package:zhixing_ai/core/logger.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/data/models/conversation.dart';
import 'package:zhixing_ai/core/data/repository/dashboard_repository.dart';
import 'package:zhixing_ai/core/data/repository/settings_repository.dart';
import 'package:zhixing_ai/features/chat/engine/client/chat_client.dart';
import 'package:zhixing_ai/features/chat/engine/client/cloud_chat_client.dart';
import 'package:zhixing_ai/features/chat/engine/client/local_chat_client.dart';

/// 异步构造 [ChatClient] 的工厂（生产按模式选实现，测试注入 fake）。
typedef ChatClientFactory = Future<ChatClient> Function();

/// 对话状态管理。模式分支收在 [ChatClient] 实现内部（本地 diff 增量 /
/// 云端窗口裁剪），Provider 只面向接口，收发均不含模式判断。
///
/// 两种生命周期：新对话只传 [topic]（内部加欢迎语，首次发言建 DB 记录）；
/// 恢复对话传 [conversation]（加载其消息 / ID / 轮次）。
class ChatProvider extends ChangeNotifier {
  final String _topic;
  final ConversationService _conversationService;

  /// 显式指定的模式；null 时延迟到 [_defaultClientFactory] 读取
  /// [SettingsRepository]（构造期不碰单例，测试免初始化）。
  final ChatMode? _explicitMode;
  final ChatClient? _injectedClient;
  final ChatClientFactory? _clientFactory;
  final DashboardRepository _dashboardRepo;

  ChatClient? _client;
  bool _isModelLoading = false;
  String? _modelError;

  bool get isModelReady => _client != null && _client!.isReady;
  bool get isModelLoading => _isModelLoading;
  String? get modelError => _modelError;
  bool get hasModelError => _modelError != null;

  int _round;
  bool _isThinking = false;
  String? _error;
  final List<ChatMessage> _messages;

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  int get round => _round;
  bool get isThinking => _isThinking;
  String? get error => _error;

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  int? _activeConversationId;

  int? get activeConversationId => _activeConversationId;
  ConversationService get conversationService => _conversationService;

  Future<void> startConversation() async {
    _activeConversationId = await _conversationService.createConversation(_topic);
  }

  ChatProvider({
    required String topic,
    Conversation? conversation,
    ConversationService? conversationService,
    ChatMode? mode,
    ChatClient? client,
    ChatClientFactory? clientFactory,
    DashboardRepository? dashboardRepo,
  })  : _explicitMode = mode,
        _injectedClient = client,
        // ignore: prefer_initializing_formals
        _clientFactory = clientFactory,
        _dashboardRepo = dashboardRepo ?? DashboardRepository(),
        _topic = topic,
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
    _client?.dispose();
    super.dispose();
  }

  static List<ChatMessage> _buildWelcome(String topic) {
    final opening = topic.isNotEmpty
        ? '用户提到想聊聊$topic——请详细说说你的想法，我来帮你分析。'
        : '用户请讲，助手在此。有任何困惑或打算，尽管说来——我帮你看清局势，给出策略。';

    return [ChatMessage(role: MessageRole.ai, content: opening, round: 0)];
  }

  /// 云端模式不加载本地模型（输入解锁更快）；本地经 [LlamaService.ensureReady]。
  /// 两者都读取 Dashboard 已有目标注入上下文。
  Future<void> loadModel() async {
    _isModelLoading = true;
    notifyListeners();

    try {
      final client = _injectedClient ??
          await (_clientFactory ?? _defaultClientFactory)();

      final activeGoals = await _dashboardRepo.getActiveGoals();

      if (!await client.initialize(existingGoals: activeGoals)) {
        throw Exception('对话客户端初始化失败');
      }
      _client = client;
    } catch (e) {
      AppLogger.warn('ChatProvider', '模型加载失败，将使用 Mock 回复: $e');
      _modelError = e.toString();
    } finally {
      _isModelLoading = false;
      notifyListeners();
    }
  }

  ChatMode get _resolvedMode =>
      _explicitMode ??
      (SettingsRepository.instance.chatCloudMode
          ? ChatMode.cloud
          : ChatMode.local);

  Future<ChatClient> _defaultClientFactory() async {
    switch (_resolvedMode) {
      case ChatMode.cloud:
        // BYOK 直连：三件套齐全才可用（设置层有门禁，此处防御兜底）。
        final repo = SettingsRepository.instance;
        if (!repo.isCloudApiConfigured) {
          throw StateError('云端模式未配置 API（地址/Key/模型名）');
        }
        return CloudChatClient(
          baseUrl: repo.cloudApiBaseUrl,
          apiKey: repo.cloudApiKey,
          modelName: repo.cloudModelName,
        );
      case ChatMode.local:
        final engine = await LlamaService.instance
            .ensureReady(gpuLayers: SettingsRepository.instance.gpuLayers);
        return LocalChatClient(engine: engine);
    }
  }

  Future<void> retryLoadModel() async {
    _modelError = null;
    await loadModel();
  }

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
      final client = _client;
      if (client == null || !client.isReady) {
        _messages[aiMessageIndex] = ChatMessage(
          role: MessageRole.ai,
          content: _generateMockResponse(),
          round: _round,
        );
        return;
      }

      // 去掉尾部空 AI 占位符 → 尾部恰为本轮用户消息。
      final history = _messages.sublist(0, _messages.length - 1);
      await _consume(client.generateResponse(history), aiMessageIndex);
    } catch (e, stack) {
      AppLogger.error('ChatProvider', '推理失败', e, stack);
      if (e is TimeoutException) {
        // 云端帧间空闲超时：半截 markdown 可能残缺（截断渲染异常），丢弃并提示重试。
        final partialLen = _messages[aiMessageIndex].content.length;
        AppLogger.warn(
            'ChatProvider', '连接超时，丢弃 $partialLen 字符的半成品内容');
        _error = '连接超时';
        _messages[aiMessageIndex] = ChatMessage(
          role: MessageRole.ai,
          content: '连接超时了，请重新发送你的问题。',
          round: _round,
        );
      } else if (_messages[aiMessageIndex].content.isEmpty) {
        // 完全无产出：降级 Mock。
        AppLogger.warn('ChatProvider', '对话失败，降级为本地回复');
        _error = '连接失败，已使用本地回复';
        _messages[aiMessageIndex] = ChatMessage(
          role: MessageRole.ai,
          content: _generateMockResponse(),
          round: _round,
        );
      } else {
        // 已流出部分内容（非超时）：保留半成品，仅记录错误。
        _error = e.toString();
      }
    } finally {
      _round++;
      _isThinking = false;
      notifyListeners();
      _saveMessages();
    }
  }

  /// 统一消费流式回复，边收边写回 AI 消息。手动 [StreamSubscription]，
  /// 供 [stopGeneration] 中途取消。
  Future<void> _consume(Stream<String> stream, int aiMessageIndex) {
    final completer = Completer<void>();
    _generationCompleter = completer;

    final buffer = StringBuffer();
    _activeSubscription = stream.listen(
      (delta) {
        buffer.write(delta);
        _messages[aiMessageIndex] = ChatMessage(
          role: MessageRole.ai,
          content: buffer.toString(),
          round: _round,
        );
        notifyListeners();
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.completeError(e);
        _activeSubscription = null;
        _generationCompleter = null;
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
        _activeSubscription = null;
        _generationCompleter = null;
      },
      cancelOnError: true,
    );

    return completer.future;
  }

  Completer<void>? _generationCompleter;
  StreamSubscription<String>? _activeSubscription;

  /// 停止按钮：[_client.stop]（云端中断 socket，本地 no-op）+ 取消订阅，
  /// 已生成文本保留。完成器标记为「正常完成」→ 走 sendMessage 的 finally
  /// 正常推进轮次并保存半截内容，不进 catch 降级分支。
  void stopGeneration() {
    final sub = _activeSubscription;
    if (sub == null) return;
    _activeSubscription = null;

    _client?.stop();
    sub.cancel();

    if (_generationCompleter != null && !_generationCompleter!.isCompleted) {
      _generationCompleter!.complete();
    }
    _generationCompleter = null;
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
