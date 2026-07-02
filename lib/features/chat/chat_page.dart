import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/chat/providers/chat_provider.dart';
import 'package:socratic_ai/features/chat/widgets/chat_bubble.dart';
import 'package:socratic_ai/features/chat/widgets/chat_input.dart';
import 'package:socratic_ai/features/insights/insights_page.dart';

/// 对话页面
///
/// 用户与 AI 进行苏格拉底式深度对话的页面。
/// 集成三大组件：
/// - [ChatBubble]：消息列表（AI 追问 + 用户回答）
/// - [ChatInput]：底部输入栏
/// - [_ThinkingIndicator]：AI「思考中」的动画指示器
///
/// ## 对话流程
/// 1. 打开页面 → AI 发来欢迎消息（主动追问）
/// 2. 用户输入回答 → AI 继续追问
/// 3. 重复 5-8 轮 → 用户点击「结束对话」
/// 4. 跳转到 InsightsPage 查看对话洞察
///
/// ## Provider 结构
/// ChatPage 内部创建自己的 ChatProvider（ChangeNotifierProvider），
/// 通过 `Consumer<ChatProvider>` 监听状态变化。
/// 这和 TopicSelectionPage 不同——TopicSelectionPage 的 Provider
/// 是由父组件（main.dart）注入的，而 ChatPage 是自包含的。
class ChatPage extends StatelessWidget {
  /// 对话话题标题
  final String topic;

  const ChatPage({super.key, required this.topic});

  /// 结束对话，跳转到洞察总结页
  ///
  /// Navigator.pushReplacement：替换当前页面（不是 push），
  /// 这样用户按返回时不会回到对话页。
  void _endConversation(BuildContext context, ChatProvider chatProvider) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => InsightsPage(
          conversation: chatProvider.messages,
          topic: topic,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      // 创建 ChatProvider：传入话题，自动生成欢迎消息
      create: (_) => ChatProvider(topic: topic),

      // Consumer 监听 ChatProvider 的变化
      // 参数：(context, chatProvider, child)
      // 每当 ChatProvider 调用 notifyListeners()，builder 就会重新执行
      child: Consumer<ChatProvider>(
        builder: (context, chatProvider, _) {
          return Scaffold(
            // =========================================================
            // AppBar：话题标题 + 轮次 + 结束对话按钮
            // =========================================================
            appBar: AppBar(
              // 标题：话题名 + 轮次（竖排）
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(topic, style: const TextStyle(fontSize: 16)),
                  Text(
                    '第 ${chatProvider.round} 轮',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),

              // 右侧按钮
              actions: [
                // 「结束对话」按钮
                TextButton.icon(
                  onPressed: () => _endConversation(context, chatProvider),
                  icon: const Icon(
                    Icons.stop_circle_outlined,
                    color: AppTheme.secondary, // 暖棕色
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

            // =========================================================
            // Body：消息列表 + 思考指示器 + 输入栏
            // =========================================================
            body: Column(
              children: [
                // ── 消息列表（占据剩余空间）──
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 12),

                    // itemCount：消息数量
                    itemCount: chatProvider.messages.length,

                    // itemBuilder：为每条消息构建一个 ChatBubble
                    // index 从 0 开始，对应 messages 列表的索引
                    itemBuilder: (context, index) {
                      return ChatBubble(
                        message: chatProvider.messages[index],
                      );
                    },
                  ),
                ),

                // ── AI 思考中指示器（条件显示）──
                // if (true) 展开 [...] 中所有组件
                if (chatProvider.isThinking)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Row(
                      children: [
                        SizedBox(width: 48), // 左侧留白，与 AI 头像对齐
                        _ThinkingIndicator(),
                      ],
                    ),
                  ),

                // ── 底部输入栏 ──
                ChatInput(
                  onSend: (message) {
                    // 用户发送消息 → ChatProvider 处理（添加用户消息 + AI 追问）
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
