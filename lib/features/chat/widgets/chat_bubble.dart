import 'package:flutter/material.dart';
import 'package:zhixing_ai/core/models/chat_models.dart';
import 'package:zhixing_ai/core/theme.dart';
import 'package:zhixing_ai/features/chat/widgets/markdown_message_view.dart';

/// 聊天气泡组件
///
/// 根据消息角色显示不同的对齐方式和颜色：
/// - **AI 消息**：左对齐，白色背景 + 灰色阴影，前面有头像标识
/// - **用户消息**：右对齐，鼠尾草绿背景 + 白色文字
///
/// 气泡的四个圆角会基于角色做差异化处理：
/// AI 的消息左下角更方（像对方在说话的视觉暗示），
/// 用户的消息右下角更方（像自己说话的视觉暗示）。
///
/// ## 设计参考
/// 类似微信、Telegram 等聊天应用的气泡样式，
/// 让用户一眼就能区分「谁说了什么」。
class ChatBubble extends StatelessWidget {
  /// 要显示的消息数据
  final ChatMessage message;

  /// 是否正处于流式生成中（仅最后一条 AI 消息可能为 true）
  final bool isStreaming;

  const ChatBubble({
    super.key,
    required this.message,
    this.isStreaming = false,
  });

  /// 判断这条消息是否是 AI 发出的
  ///
  /// bool get 是 Dart 的 getter 语法，调用时像属性一样：
  /// `widget._isAI` 而不是 `widget._isAI()`
  bool get _isAI => message.role == MessageRole.ai;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // 气泡之间的间距：左右 16px，上下 6px
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),

      child: Row(
        // mainAxisAlignment 控制水平方向的对齐：
        // AI 消息 → 靠左（MainAxisAlignment.start）
        // 用户消息 → 靠右（MainAxisAlignment.end）
        mainAxisAlignment: _isAI ? MainAxisAlignment.start : MainAxisAlignment.end,

        // crossAxisAlignment: CrossAxisAlignment.end 让头像和气泡底部对齐
        crossAxisAlignment: CrossAxisAlignment.end,

        children: [
          // =========================================================
          // AI 消息左侧：头像标识
          // =========================================================
          // if (_isAI) ...[...] 是 Dart 的集合展开语法：
          // 条件为 true 时，[...] 里的内容才被展开到 children 列表中
          if (_isAI) ...[
            // CircleAvatar：圆形头像组件
            const CircleAvatar(
              radius: 16, // 半径 16px → 直径 32px
              backgroundColor: AppTheme.primary, // 鼠尾草绿底色
              child: Text(
                'AI',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),

            // 头像和气泡之间的间距
            const SizedBox(width: 8),
          ],

          // =========================================================
          // 消息气泡（AI 和用户共享）
          // =========================================================
          // Flexible 让气泡在空间不足时自动换行（防止长文本溢出屏幕）
          Flexible(
            child: Container(
              // BoxConstraints 限制气泡的最大宽度为 260px
              // 防止短消息气泡太窄、长消息气泡太宽
              constraints: const BoxConstraints(maxWidth: 260),

              // 内边距：水平 16px，垂直 12px
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),

              decoration: BoxDecoration(
                // AI：白色背景，用户：鼠尾草绿背景
                color: _isAI ? Colors.white : AppTheme.primary,

                // 圆角：四个角分别控制
                // AI：左下角更方（4px 圆角），其他三角 16px
                // 用户：右下角更方（4px 圆角），其他三角 16px
                // 这种不对称设计是聊天 UI 的经典模式
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: _isAI
                      ? const Radius.circular(4)
                      : const Radius.circular(16),
                  bottomRight: _isAI
                      ? const Radius.circular(16)
                      : const Radius.circular(4),
                ),

                // 轻微阴影，增加层次感
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),

              child: _isAI
                  ? MarkdownMessageView(
                      content: message.content,
                      isComplete: !isStreaming,
                      baseStyle: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 15,
                        height: 1.5, // 行高 1.5 倍，增加可读性
                      ),
                    )
                  : Text(
                      message.content,
                      style: TextStyle(
                        // 用户消息：白色文字
                        color: Colors.white,
                        fontSize: 15,
                        height: 1.5, // 行高 1.5 倍，增加可读性
                      ),
                    ),
            ),
          ),

          // =========================================================
          // 用户消息右侧：留白（与左侧头像形成视觉平衡）
          // =========================================================
          if (!_isAI) const SizedBox(width: 8),
        ],
      ),
    );
  }
}
