import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:socratic_ai/core/llama_service.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/chat/providers/chat_provider.dart';
import 'package:socratic_ai/features/chat/widgets/chat_bubble.dart';
import 'package:socratic_ai/features/chat/widgets/chat_input.dart';
import 'package:socratic_ai/features/insights/insights_page.dart';

/// 对话页面
///
/// 用户与 AI 进行苏格拉底式深度对话的页面。
/// 进入页面时自动加载 Qwen 1.5B 模型（约 13 秒），加载期间显示进度。
/// 模型加载失败不影响使用——自动回退到 Mock 回复。
///
/// ## 对话流程
/// 1. 打开页面 → 后台加载模型 → AI 发来欢迎消息
/// 2. 用户输入回答 → AI 追问（真实推理 / Mock 回退）
/// 3. 重复 5-8 轮 → 用户点击「结束对话」
/// 4. 跳转到 InsightsPage 查看对话洞察
class ChatPage extends StatefulWidget {
  final String topic;

  const ChatPage({super.key, required this.topic});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  /// 模型加载进度：null = 未开始 / true = 加载中 / false = 完成
  bool? _modelLoading;

  /// 消息列表的滚动控制器，用于新消息到达时自动滚到底部
  final ScrollController _scrollController = ScrollController();

  /// 上一次渲染时的消息数量，变化时触发自动滚动
  int _lastMessageCount = -1;

  @override
  void initState() {
    super.initState();
    _loadModel();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 后台加载端侧大模型（不阻塞 UI）
  Future<void> _loadModel() async {
    final service = LlamaService();
    if (service.isLoaded || service.isLoading) return;

    setState(() => _modelLoading = true);

    try {
      // ── dylib 路径：从 App Bundle 内部加载（Build Phase 自动复制） ──
      // Platform.resolvedExecutable = socratic_ai.app/Contents/MacOS/socratic_ai
      // dylib 被 Copy Files Build Phase 复制到 Contents/Frameworks/
      final executable = File(Platform.resolvedExecutable);
      final bundleContents = executable.parent.parent; // MacOS → Contents
      final libPath = '${bundleContents.path}/Frameworks/libllama.dylib';

      // ── 模型路径：开发阶段仍是项目目录的绝对路径（1GB 太大，不打包） ──
      const modelPath =
          '/Users/superjie-mac/projects/socratic-ai/assets/models/qwen2.5-1.5b-instruct-q4_k_m.gguf';

      await service.loadModel(
        modelPath: modelPath,
        libraryPath: libPath,
      );
    } catch (e) {
      debugPrint('[ChatPage] 模型加载失败，将使用 Mock 回复: $e');
    } finally {
      if (mounted) setState(() => _modelLoading = false);
    }
  }

  void _endConversation(BuildContext context, ChatProvider chatProvider) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => InsightsPage(
          conversation: chatProvider.messages,
          topic: widget.topic,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ChatProvider(topic: widget.topic),
      child: Consumer<ChatProvider>(
        builder: (context, chatProvider, _) {
          // 消息数量变化时，下一帧自动滚动到底部
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
                  onPressed: () => _endConversation(context, chatProvider),
                  icon: const Icon(
                    Icons.stop_circle_outlined,
                    color: AppTheme.secondary,
                    size: 18,
                  ),
                  label: const Text(
                    '结束对话',
                    style: TextStyle(
                      color: AppTheme.secondary,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
            body: Stack(
              children: [
                Column(
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
                // 模型加载遮罩（不阻塞 UI，显示加载提示）
                if (_modelLoading == true)
                  Positioned(
                    top: 8,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.surface.withAlpha(240),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Text(
                          '正在加载 AI 模型（约 15 秒）...',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ),
                    ),
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
///
/// 三个绿点依次跳动 + "正在思考..." 文字。
/// 使用 AnimationController 驱动缩放动画。
///
/// ## StatefulWidget + SingleTickerProviderStateMixin
/// 需要动画，所以是 StatefulWidget。
/// SingleTickerProviderStateMixin 提供 Ticker（每帧回调），
/// 供 AnimationController 使用。
class _ThinkingIndicator extends StatefulWidget {
  const _ThinkingIndicator();

  @override
  State<_ThinkingIndicator> createState() => _ThinkingIndicatorState();
}

class _ThinkingIndicatorState extends State<_ThinkingIndicator>
    with SingleTickerProviderStateMixin {
  /// AnimationController：控制动画的播放
  ///
  /// duration：一次动画循环的时间（1200ms）
  /// vsync: this — 由 this（当前 State）提供帧回调
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat(); // repeat() = 循环播放
  }

  @override
  void dispose() {
    _controller.dispose(); // 释放动画资源
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // AnimatedBuilder：监听 controller 的值变化，
    // 每帧重建 UI（Dart 3 中用 AnimatedBuilder 替代 deprecated 的 AnimatedWidget）
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Row(
          mainAxisSize: MainAxisSize.min, // 只占用实际需要的宽度
          children: [
            _buildDot(0), // 第一个点（立即开始跳动）
            const SizedBox(width: 4),
            _buildDot(1), // 第二个点（延迟 0.2 开始跳动）
            const SizedBox(width: 4),
            _buildDot(2), // 第三个点（延迟 0.4 开始跳动）
            const SizedBox(width: 8),
            const Text(
              '正在思考...',
              style: TextStyle(
                fontSize: 13,
                color: AppTheme.textSecondary,
              ),
            ),
          ],
        );
      },
    );
  }

  /// 构建一个跳动的小圆点
  ///
  /// [index]：点的序号（0/1/2），用于计算延迟
  Widget _buildDot(int index) {
    // 每个点延迟 0.2（1200ms × 0.2），形成依次跳动的波浪效果
    final delay = index * 0.2;

    // 计算出当前点应该的缩放值
    // clamp(0.0, 1.0) 防止负值
    final progress = (_controller.value - delay).clamp(0.0, 1.0);

    // 把 0→1 的线性进度转成 0.5→1→0.5 的缩放值
    // 前半段变大（0→1），后半段变小（1→0）
    final scale = 0.5 + 0.5 * (progress < 0.5 ? progress * 2 : 2 - progress * 2);

    return Transform.scale(
      scale: scale,
      child: Container(
        width: 6,
        height: 6,
        decoration: const BoxDecoration(
          color: AppTheme.primary, // 鼠尾草绿
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
