import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/chat/providers/chat_provider.dart';
import 'package:socratic_ai/features/chat/widgets/chat_bubble.dart';
import 'package:socratic_ai/features/chat/widgets/chat_input.dart';
import 'package:socratic_ai/features/history/providers/conversation_provider.dart';
import 'package:socratic_ai/features/insights/insights_page.dart';

/// 对话页面
///
/// 用户与 AI 进行苏格拉底式深度对话。
/// 模型加载由 [ChatProvider.loadModel] 负责，加载期间显示进度。
///
/// ## 分层
/// ChatPage 只依赖：
/// - ChatProvider（Provider）
/// - ConversationProvider（Provider）
/// - chat widgets（同 feature）
/// - InsightsPage（跨 feature 页面跳转）
/// - core/theme（全局样式）
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

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _endConversation(BuildContext context) async {
    final chatProvider = context.read<ChatProvider>();
    final convProvider = context.read<ConversationProvider>();

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

    // 生成洞察
    final insight = await chatProvider.endConversation();

    // 持久化
    final activeId = convProvider.activeConversationId;
    convProvider.finishConversation(
      insight.coreInsights.isNotEmpty ? insight : null,
    );

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

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (ctx) {
        final convProvider = ctx.read<ConversationProvider>();
        late final ChatProvider provider;
        provider = ChatProvider(
          topic: widget.topic,
          onMessagesChanged: () {
            convProvider.saveMessages(provider.messages);
          },
        );

        // 创建后立即触发模型加载（异步，不阻塞 UI）
        provider.loadModel();

        return provider;
      },
      child: Consumer<ChatProvider>(
        builder: (context, chatProvider, _) {
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

          // 模型就绪时创建持久化记录（仅一次）
          if (chatProvider.isModelReady && !_conversationStarted) {
            _conversationStarted = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              context.read<ConversationProvider>().startConversation(widget.topic);
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
