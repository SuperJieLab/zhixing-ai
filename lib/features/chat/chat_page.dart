import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:socratic_ai/core/snackbar_throttle.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/chat/providers/chat_provider.dart';
import 'package:socratic_ai/features/chat/widgets/chat_bubble.dart';
import 'package:socratic_ai/features/chat/widgets/chat_input.dart';
import 'package:socratic_ai/features/insights/insights_page.dart';

/// 对话页面
///
/// 用户与 AI 进行苏格拉底式深度对话。
/// 所有持久化和业务逻辑都由 [ChatProvider] 管理，
/// ChatPage 只负责 UI 渲染和页面跳转。
class ChatPage extends StatefulWidget {
  final String topic;

  const ChatPage({super.key, required this.topic});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final ScrollController _scrollController = ScrollController();
  int _lastMessageCount = -1;
  bool _conversationStarted = false;
  bool _errorListenerSetup = false;

  /// 持有的 ChatProvider 引用（用于 dispose 时移除 listener）
  ChatProvider? _listenedProvider;

  @override
  void dispose() {
    _listenedProvider?.removeListener(_onChatError);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _endConversation(BuildContext context) async {
    final chatProvider = context.read<ChatProvider>();
    final activeId = chatProvider.activeConversationId;

    // 显示 loading 弹窗
    if (!context.mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: Center(
          child: Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: AppTheme.primary),
                  SizedBox(height: 16),
                  Text(
                    '正在生成洞察总结...',
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    // 生成洞察（ChatProvider 内部会完成持久化）
    final insight = await chatProvider.endConversation();

    // 关闭 loading，跳转
    if (!context.mounted) return;
    Navigator.pop(context);
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => InsightsPage(
          insight: insight,
          topic: widget.topic,
          messages: chatProvider.messages,
          conversationId: activeId,
        ),
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
      create: (_) {
        final provider = ChatProvider(topic: widget.topic);
        provider.loadModel();
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

          // 模型加载中 → 全屏 loading
          if (chatProvider.isModelLoading) {
            return Scaffold(
              appBar: AppBar(
                backgroundColor: AppTheme.background,
                title: Text(widget.topic),
              ),
              body: const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: AppTheme.primary),
                    SizedBox(height: 16),
                    Text(
                      '正在加载 AI 模型（约 15 秒）...',
                      style: TextStyle(color: AppTheme.textSecondary),
                    ),
                  ],
                ),
              ),
            );
          }

          // 模型加载失败 → 错误视图
          if (chatProvider.hasModelError) {
            return _buildModelErrorView(chatProvider);
          }

          // 模型就绪时创建持久化记录（仅一次）
          if (chatProvider.isModelReady && !_conversationStarted) {
            _conversationStarted = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              chatProvider.startConversation();
            });
          }

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
                  Text(widget.topic, style: const TextStyle(fontSize: 16)),
                  Text(
                    '第 ${chatProvider.round} 轮',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton.icon(
                  onPressed: () => _endConversation(context),
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
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildModelErrorView(ChatProvider provider) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        title: Text(widget.topic),
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
                onPressed: () => provider.retryLoadModel(),
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
