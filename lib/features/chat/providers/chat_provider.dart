import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:zhixing_ai/core/data/conversation_service.dart';
import 'package:zhixing_ai/core/llm/context_assembly.dart';
import 'package:zhixing_ai/core/llm/llm.dart';
import 'package:zhixing_ai/core/logger.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/data/models/conversation.dart';
import 'package:zhixing_ai/core/data/models/dashboard_models.dart';
import 'package:zhixing_ai/core/data/repository/dashboard_repository.dart';
import 'package:zhixing_ai/features/chat/prompt/conversation_strategy.dart';

/// 对话状态管理。
///
/// 业务职责只有三件（设计 §5.1）：**持消息列表**（唯一真值源）、
/// **持压缩状态实例**（[ContextState]，类型在基建）、**每轮传人设**。
/// 后端模式（本地 / 云端）由 `Llm` 服务内部解析，本类不含任何模式分支；
/// **也不持有加载 / 释放职责**（引擎生命周期归服务，就绪态经
/// `llm.readiness` 由页面消费，design §9 #4/#5）。
///
/// 两种生命周期：新对话只传 [topic]（内部加欢迎语，首次发言建 DB 记录）；
/// 恢复对话传 [conversation]（加载其消息 / ID / 轮次）。
class ChatProvider extends ChangeNotifier {
  final String _topic;
  final ConversationService _conversationService;
  final Llm _llm;
  final DashboardRepository _dashboardRepo;

  /// 人设出处（业务；唯一）。
  final ConversationStrategy _strategy = ConversationStrategy();

  /// 会话压缩状态（业务持有的实例；装配时就地更新）。
  final ContextState _contextState = ContextState();

  /// 本轮注入人设的已有目标（**每轮发言前刷新**，目标取用留在业务侧，
  /// design §10.1 #8——基建不认识 Dashboard 仓库）。
  List<Goal> _activeGoals = const [];

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
    required this._llm,
    Conversation? conversation,
    ConversationService? conversationService,
    DashboardRepository? dashboardRepo,
  })  : _dashboardRepo = dashboardRepo ?? DashboardRepository(),
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
    // 后端资源（引擎 / 交付实现）归服务所有、寿命与 App 相同，此处不释放。
    super.dispose();
  }

  static List<ChatMessage> _buildWelcome(String topic) {
    final opening = topic.isNotEmpty
        ? '用户提到想聊聊$topic——请详细说说你的想法，我来帮你分析。'
        : '用户请讲，助手在此。有任何困惑或打算，尽管说来——我帮你看清局势，给出策略。';

    return [ChatMessage(role: MessageRole.ai, content: opening, round: 0)];
  }

  /// 刷新本轮要注入人设的已有目标。
  ///
  /// 读取失败（如测试环境无 DB）不阻塞对话：沿用上次结果（首次为空），
  /// 人设退化为「无目标」版本。
  Future<void> _refreshGoals() async {
    try {
      _activeGoals = await _dashboardRepo.getActiveGoals();
    } catch (e) {
      AppLogger.warn('ChatProvider', '读取活跃目标失败（沿用上次/空）: $e');
    }
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
      // 后端未就绪（模型缺失 / 云端未配齐）→ Mock 兜底；就绪化由服务驱动
      // （页面消费 llm.readiness 表达 loading / 错误，这里不阻塞）。
      if (!_llm.isReady) {
        _messages[aiMessageIndex] = ChatMessage(
          role: MessageRole.ai,
          content: _generateMockResponse(),
          round: _round,
        );
        return;
      }

      // 每轮刷新目标（人设随轮注入，不缓存于服务）。
      await _refreshGoals();

      // 去掉尾部空 AI 占位符 → 尾部恰为本轮用户消息。
      final history = _messages.sublist(0, _messages.length - 1);
      await _consume(
        _llm.converse(
          history,
          systemPrompt: _strategy.buildSystemPrompt(existingGoals: _activeGoals),
          state: _contextState,
        ),
        aiMessageIndex,
      );
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

  /// 停止按钮：[_llm.stop]（云端中断 socket，本地 no-op）+ 取消订阅，
  /// 已生成文本保留。完成器标记为「正常完成」→ 走 sendMessage 的 finally
  /// 正常推进轮次并保存半截内容，不进 catch 降级分支。
  void stopGeneration() {
    final sub = _activeSubscription;
    if (sub == null) return;
    _activeSubscription = null;

    _llm.stop();
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
