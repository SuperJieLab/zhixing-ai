import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:zhixing_ai/core/engine/conversation_service.dart';
import 'package:zhixing_ai/core/engine/llama_service.dart';
import 'package:zhixing_ai/core/logger.dart';
import 'package:zhixing_ai/core/models/chat_models.dart';
import 'package:zhixing_ai/core/models/conversation.dart';
import 'package:zhixing_ai/core/repository/dashboard_repository.dart';
import 'package:zhixing_ai/core/repository/settings_repository.dart';
import 'package:zhixing_ai/features/chat/engine/chat_client.dart';
import 'package:zhixing_ai/features/chat/engine/cloud_chat_client.dart';
import 'package:zhixing_ai/features/chat/engine/local_chat_client.dart';

/// 异步构造 [ChatClient] 的工厂（生产环境按 [_mode] 选实现，测试注入 fake）。
typedef ChatClientFactory = Future<ChatClient> Function();

/// 对话状态管理
///
/// 管理一次助手对话的完整生命周期：
///   1. 初始化客户端 → [loadModel] 构造 [ChatClient]（本地/云端）并注入已有目标
///   2. 对话交互 → [sendMessage] 驱动流式生成回复
///   3. 持久化 → 每轮保存 messages 到 DB，通过 [ConversationService]
///   4. 结束 → ChatPage 调用 _endConversation，跳转 Brief 页
///
/// ## 两种模式
/// - 新对话：只传 [topic]，Provider 内部加欢迎语，首次发言时创建 DB 记录
/// - 恢复：传 [conversation]，Provider 加载其消息 / ID / 轮次
///
/// 模式分支收在 [ChatClient] 实现内部（本地 diff 增量 append / 云端窗口裁剪），
/// Provider 只面向接口：单 [_client] 字段，收发均不含模式判断。
class ChatProvider extends ChangeNotifier {
  final String _topic;
  final ConversationService _conversationService;
  final ChatMode _mode;

  /// 测试/页面注入的客户端实例；非空时 [loadModel] 直接复用，不走工厂。
  final ChatClient? _injectedClient;

  /// 测试注入的客户端工厂；非空时优先于 [_defaultClientFactory]。
  final ChatClientFactory? _clientFactory;

  /// 测试注入的目标仓库；缺省 [DashboardRepository]（测试环境无 DB 会抛错）。
  final DashboardRepository _dashboardRepo;

  // ================================================================
  // 客户端状态
  // ================================================================

  ChatClient? _client;
  bool _isModelLoading = false;
  String? _modelError;

  bool get isModelReady => _client != null && _client!.isReady;
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
    ChatMode? mode,
    ChatClient? client,
    ChatClientFactory? clientFactory,
    DashboardRepository? dashboardRepo,
  })  : _mode = mode ??
            (SettingsRepository.instance.chatCloudMode
                ? ChatMode.cloud
                : ChatMode.local),
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
  // 客户端初始化
  // ================================================================

  /// 初始化对话客户端。
  ///
  /// 云端模式不再加载本地模型（CloudChatClient.initialize 为 no-op），
  /// 输入解锁更快；本地模式经 [LlamaService.ensureReady] 加载引擎。
  /// 两者都会读取 Dashboard 已有目标注入上下文（本地进系统提示词，
  /// 云端暂存待 ② 随请求发送）。
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

  /// 默认客户端工厂：按模式选实现。
  Future<ChatClient> _defaultClientFactory() async {
    switch (_mode) {
      case ChatMode.cloud:
        return CloudChatClient();
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
      final client = _client;
      if (client == null || !client.isReady) {
        _messages[aiMessageIndex] = ChatMessage(
          role: MessageRole.ai,
          content: _generateMockResponse(),
          round: _round,
        );
        return;
      }

      // 历史去掉尾部空 AI 占位符 → 尾部恰为本轮用户消息。
      // 本地 client 对此历史做 diff 增量 append；云端 client 取窗口裁剪。
      final history = _messages.sublist(0, _messages.length - 1);
      await _consume(client.generateResponse(history), aiMessageIndex);
    } catch (e, stack) {
      AppLogger.error('ChatProvider', '推理失败', e, stack);
      if (e is TimeoutException) {
        // 帧间空闲超时（云端 SSE 特有，本地生成不抛超时）：
        // 丢弃可能残缺的半截 markdown（截断渲染异常），提示用户重试。
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
        // 完全无产出（云端连接失败等）：降级为本地 Mock 回复，给出友好提示。
        AppLogger.warn('ChatProvider', '对话失败，降级为本地回复');
        _error = '连接失败，已使用本地回复';
        _messages[aiMessageIndex] = ChatMessage(
          role: MessageRole.ai,
          content: _generateMockResponse(),
          round: _round,
        );
      } else {
        // 已流出部分内容（非超时异常）：保留半成品，仅记录错误。
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

  /// 统一消费一段流式回复，边收边写回 AI 消息并通知监听者。
  ///
  /// 手动 [StreamSubscription] 管理，使 [stopGeneration] 能中途取消订阅。
  /// 正常完成（onDone）或中断（stopGeneration）后清空 [_activeSubscription] /
  /// [_generationCompleter]，避免悬挂引用。
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

  /// 与本轮流式消费对应的完成器，[stopGeneration] 通过它把中断标记为正常完成。
  Completer<void>? _generationCompleter;

  /// 当前进行中的流式订阅，供 [stopGeneration] 取消。
  /// 自然结束或中断后清空。
  StreamSubscription<String>? _activeSubscription;

  /// 中断当前正在进行的生成
  ///
  /// 用于输入栏停止按钮：调 [_client.stop()]（云端中断 socket → 服务端感知断开；
  /// 本地为 no-op）并取消消费订阅（已生成文本保留）。完成器标记为「正常完成」，
  /// 使 sendMessage 的 finally 正常推进轮次并保存半截内容，不进 catch 降级分支。
  void stopGeneration() {
    final sub = _activeSubscription;
    if (sub == null) return;
    _activeSubscription = null;

    _client?.stop();
    sub.cancel();

    if (_generationCompleter != null && !_generationCompleter!.isCompleted) {
      _generationCompleter!.complete(); // 视为正常结束：走 finally，不进 catch。
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
