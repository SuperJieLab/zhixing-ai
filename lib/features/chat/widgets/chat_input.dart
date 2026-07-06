import 'package:flutter/material.dart';
import 'package:socratic_ai/core/theme.dart';

/// 对话页底部输入栏
///
/// 包含一个圆角输入框和一个圆形发送按钮。
/// 用户输入文字后按回车或点击发送按钮，消息会通过 [onSend] 回调传出去。
///
/// ## 为什么是 StatefulWidget？
/// 因为需要管理 [TextEditingController] —— 一个有状态的对象。
/// controller 持有输入框的文本内容和光标位置，这些在用户打字时不断变化，
/// 所以必须用 StatefulWidget 来承载这套状态。
///
/// ## TextEditingController 的作用
/// - 获取输入框文本：`_controller.text`
/// - 清空输入框：`_controller.clear()`
/// - 释放资源：`_controller.dispose()`（必须在 dispose() 中调用，防止内存泄漏）
///
/// ## 使用方式
/// ```dart
/// ChatInput(
///   onSend: (message) {
///     chatProvider.sendMessage(message);
///   },
/// )
/// ```
class ChatInput extends StatefulWidget {
  /// 用户发送消息时的回调
  ///
  /// 参数 [message] 是用户输入的文本（已 trim 处理）。
  /// 如果不需要处理发送事件（纯展示），可以不传。
  final void Function(String message)? onSend;

  const ChatInput({super.key, this.onSend});

  /// 创建 State 对象
  ///
  /// StatefulWidget 和 State 是分离的：
  /// - Widget 本身是不可变的（配置）
  /// - State 是可变的（状态），由 Flutter 框架管理生命周期
  @override
  State<ChatInput> createState() => _ChatInputState();
}

/// ChatInput 的状态类
///
/// 私有类（_ 前缀），外部不能直接访问。
/// 通过 widget.onSend 访问父 Widget 的回调。
class _ChatInputState extends State<ChatInput> {
  /// TextEditingController：管理输入框的文本和光标
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  /// 处理发送逻辑
  ///
  /// 1. 获取并 trim 输入文本
  /// 2. 空文本则什么都不做
  /// 3. 触发 onSend 回调（外部处理消息逻辑）
  /// 4. 清空输入框
  void _handleSubmit() {
    // trim() 去掉首尾空格
    final text = _controller.text.trim();

    // 空内容不发送
    if (text.isEmpty) return;

    // 触发 onSend 回调
    // ?.call() 是 Dart 的安全调用语法：
    // 如果 onSend 为 null，什么都不发生
    widget.onSend?.call(text);

    // 清空输入框
    _controller.clear();
  }

  /// 释放资源
  ///
  /// dispose() 在 Widget 从树中移除时调用。
  /// TextEditingController 必须在这里释放，否则会内存泄漏。
  @override
  void dispose() {
    _controller.dispose();
    super.dispose(); // 调用父类 dispose，Flutter 框架要求
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      // 内边距：上 16、左右 16、下 8
      // 下边距较小，因为 SafeArea 会处理底部安全区域
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),

      decoration: BoxDecoration(
        color: Colors.white,

        // 顶部分隔线：区分输入栏和上面的消息列表
        border: Border(
          top: BorderSide(color: Colors.grey.shade200),
        ),
      ),

      // SafeArea 确保输入栏不会被 iPhone 底部横条遮挡
      child: SafeArea(
        child: Row(
          children: [
            // =========================================================
            // 左侧：输入框（占据剩余空间）
            // =========================================================
            Expanded(
              child: TextField(
                // controller 连接数据和 UI
                controller: _controller,

                // textInputAction: 键盘右下角显示「完成」按钮
                textInputAction: TextInputAction.done,

                // onSubmitted: 用户按键盘上的「完成」键触发
                // (_) 表示不关心传入的字符串参数（因为 controller 已经持有）
                onSubmitted: (_) => _handleSubmit(),

                decoration: InputDecoration(
                  hintText: '输入你的回答...',
                  hintStyle: const TextStyle(
                    color: AppTheme.textSecondary,
                  ),

                  // 背景色和填充
                  filled: true,
                  fillColor: AppTheme.surface, // 暖白底色

                  // 内容内边距
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),

                  // 圆角边框（无边框线）
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),

            const SizedBox(width: 8),

            // =========================================================
            // 右侧：发送按钮（圆形，鼠尾草绿底色 + 白色飞机图标）
            // =========================================================
            Container(
              decoration: const BoxDecoration(
                color: AppTheme.primary,
                shape: BoxShape.circle, // 圆形
              ),
              child: IconButton(
                icon: const Icon(
                  Icons.send_rounded,
                  color: Colors.white,
                  size: 20,
                ),
                onPressed: _handleSubmit,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
