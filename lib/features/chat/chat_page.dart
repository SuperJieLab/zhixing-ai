import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:zhixing_ai/core/data/models/conversation.dart';
import 'package:zhixing_ai/core/model_gateway.dart';
import 'package:zhixing_ai/features/chat/utils/snackbar_throttle.dart';
import 'package:zhixing_ai/core/ui/theme.dart';
import 'package:zhixing_ai/features/chat/providers/chat_provider.dart';
import 'package:zhixing_ai/features/chat/widgets/chat_bubble.dart';
import 'package:zhixing_ai/features/chat/widgets/chat_input.dart';
import 'package:zhixing_ai/features/strategy_brief/strategy_brief_page.dart';

/// 自定义 [ChatProvider] 构造工厂（测试注入缝）。
typedef ChatProviderFactory = ChatProvider Function({
  required String topic,
  Conversation? conversation,
});

/// 对话页面。[conversation] null → 新对话；有值 → 恢复已有对话。
class ChatPage extends StatefulWidget {
  final String topic;
  final Conversation? conversation;

  final ChatProviderFactory? providerFactory;

  const ChatPage({
    super.key,
    required this.topic,
    this.conversation,
    this.providerFactory,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final ScrollController _scrollController = ScrollController();
  int _lastMessageCount = -1;
  bool _errorListenerSetup = false;

  /// 模型服务门面（就绪态消费 + 进入页面兜底加载；由 Provider 树提供）。
  late final ModelGateway _gateway = context.read<ModelGateway>();

  /// 持有的 ChatProvider 引用（用于 dispose 时移除 listener）
  ChatProvider? _listenedProvider;

  String get _displayTopic => widget.topic.isNotEmpty ? widget.topic : '新对话';

  @override
  void initState() {
    super.initState();
    // 进会话未就绪 → 异步兜底（design §9 #4；服务冷启动已预热，此处只补漏）。
    // 失败不抛——就绪态转 failed 由下方错误视图表达。
    if (_gateway.readiness.value.phase != LlmPhase.ready) {
      unawaited(_gateway.ensureReady().catchError((Object _) {}));
    }
  }

  @override
  void dispose() {
    _listenedProvider?.removeListener(_onChatError);
    _scrollController.dispose();
    super.dispose();
  }

  /// 结束对话 → 跳转分析页。
  ///
  /// [chatProvider] 由调用方（[build] 内已从 `Consumer` 取到）显式传入，
  /// **不可在此 `context.read<ChatProvider>()`**：该 Provider 由本页
  /// [build] 创建，是本元素的**后代**，而 State.context 位于其**祖先侧**，
  /// 查找必然抛 `ProviderNotFoundException`。
  void _endConversation(ChatProvider chatProvider) {
    final activeId = chatProvider.activeConversationId;

    if (!context.mounted) return;

    // 构造 conversation 对象：新建时用 widget.topic+最新消息，恢复时更新消息
    Conversation conversation;
    if (widget.conversation != null) {
      // 复用缓存的 Conversation 实例，原位更新 messages
      conversation = widget.conversation!;
      conversation.messages = chatProvider.messages;
    } else {
      conversation = Conversation(
        id: activeId,
        topic: widget.topic.isNotEmpty ? widget.topic : '新对话',
        messages: chatProvider.messages,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
    }

    // 注册到 Identity Map 缓存
    chatProvider.conversationService.cacheConversation(conversation);

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => StrategyBriefPage(conversation: conversation),
      ),
    );
  }

  void _onChatError() {
    final provider = _listenedProvider;
    if (provider == null || !mounted) return;
    final error = provider.error;
    if (error != null) {
      SnackBarThrottle.show(context, 'AI 推理遇到问题，当前为兜底回复');
      provider.clearError();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) {
        final factory = widget.providerFactory;
        // 门面实例由 composition root 构造、Provider 树持有（业务只认门面）。
        // 加载 / 就绪归服务（gateway.readiness），这里不再触发 loadModel。
        final provider = factory != null
            ? factory(topic: widget.topic, conversation: widget.conversation)
            : ChatProvider(
                topic: widget.topic,
                conversation: widget.conversation,
                gateway: context.read<ModelGateway>(),
              );
        return provider;
      },
      child: Consumer<ChatProvider>(
        builder: (context, chatProvider, _) {
          // 设置推理错误监听器（仅一次）
          if (!_errorListenerSetup) {
            _errorListenerSetup = true;
            _listenedProvider = chatProvider;
            chatProvider.addListener(_onChatError);
          }

          // 就绪态由服务表达（不感知本地 / 云端）：loading / 失败 /
          // 正常三种视图。idle 视同 loading（兜底 ensure 在 initState 已发起）。
          return ValueListenableBuilder<LlmReadiness>(
            valueListenable: _gateway.readiness,
            builder: (context, readiness, child) {
              switch (readiness.phase) {
                case LlmPhase.ready:
                  return child!;
                case LlmPhase.failed:
                  return _buildModelErrorView(() async {
                    // ensureReady 失败会再转 failed（错误视图本就为此存在）；
                    // 此处吞掉异常本身，避免成为未处理的异步错误。
                    try {
                      await _gateway.ensureReady();
                    } catch (_) {}
                  });
                case LlmPhase.idle:
                case LlmPhase.loading:
                  return _buildLoadingView();
              }
            },
            child: _buildChatView(chatProvider),
          );
        },
      ),
    );
  }

  /// 全屏 loading（端侧引擎加载约 15 秒量级；云端瞬时，通常一闪而过）。
  Widget _buildLoadingView() {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        title: Text(_displayTopic),
      ),
      body: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: AppTheme.primary),
            SizedBox(height: 16),
            Text(
              '正在准备 AI（本地模型首次约 15 秒）...',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  /// 正常对话视图（消息列表 + 输入框）。
  Widget _buildChatView(ChatProvider chatProvider) {
    // 自动滚动
    if (chatProvider.messages.length != _lastMessageCount) {
      _lastMessageCount = chatProvider.messages.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    }

    return Scaffold(
            appBar: AppBar(
              backgroundColor: AppTheme.background,
              surfaceTintColor: Colors.transparent,
              scrolledUnderElevation: 0,
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_displayTopic, style: const TextStyle(fontSize: 16)),
                  Text(
                    chatProvider.round > 1
                        ? '第 ${chatProvider.round - 1} 轮'
                        : '新对话',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton.icon(
                  onPressed: () => _endConversation(chatProvider),
                  icon: const Icon(
                    Icons.stop_circle_outlined,
                    color: AppTheme.secondary,
                    size: 18,
                  ),
                  label: const Text(
                    '结束对话',
                    style: TextStyle(color: AppTheme.secondary, fontSize: 13),
                  ),
                ),
              ],
            ),
            body: Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    itemCount: chatProvider.messages.length,
                    itemBuilder: (context, index) {
                      return ChatBubble(
                        message: chatProvider.messages[index],
                        isStreaming: chatProvider.isThinking &&
                            index == chatProvider.messages.length - 1,
                      );
                    },
                  ),
                ),
                if (chatProvider.isThinking)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Row(
                      children: [
                        SizedBox(width: 48),
                        _ThinkingIndicator(),
                      ],
                    ),
                  ),
                ChatInput(
                  onSend: (message) {
                    if (message.length > 3000) {
                      SnackBarThrottle.show(context, '回答过长（${message.length}/3000），请精简后发送');
                      return;
                    }
                    chatProvider.sendMessage(message);
                  },
                  isThinking: chatProvider.isThinking,
                  onStop: () => chatProvider.stopGeneration(),
                ),
              ],
            ),
          );
  }

  Widget _buildModelErrorView(VoidCallback onRetry) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        title: Text(_displayTopic),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 64, color: AppTheme.error),
              const SizedBox(height: 16),
              const Text(
                'AI 模型加载失败',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '请确保设备有足够存储空间并重试',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text(
                  '返回',
                  style: TextStyle(color: AppTheme.textSecondary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// AI「思考中」动画指示器
class _ThinkingIndicator extends StatefulWidget {
  const _ThinkingIndicator();

  @override
  State<_ThinkingIndicator> createState() => _ThinkingIndicatorState();
}

class _ThinkingIndicatorState extends State<_ThinkingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildDot(0),
            const SizedBox(width: 4),
            _buildDot(1),
            const SizedBox(width: 4),
            _buildDot(2),
            const SizedBox(width: 8),
            const Text(
              '正在思考...',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
            ),
          ],
        );
      },
    );
  }

  Widget _buildDot(int index) {
    final delay = index * 0.2;
    final progress = (_controller.value - delay).clamp(0.0, 1.0);
    final scale =
        0.5 + 0.5 * (progress < 0.5 ? progress * 2 : 2 - progress * 2);

    return Transform.scale(
      scale: scale,
      child: Container(
        width: 6,
        height: 6,
        decoration: const BoxDecoration(
          color: AppTheme.primary,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
