import 'package:flutter/material.dart';

/// 对话页面（当前为 stub 占位页）
///
/// 目前只是一个占位页面，显示话题标题。
/// Task 7-9 中会被替换为完整的 AI 对话界面。
///
/// ## 为什么需要 stub
/// TopicSelectionPage 在用户点击话题后要跳转到 ChatPage，
/// 但 ChatPage 还没有实现。先放一个最小占位，让路由能跑通，
/// 后续再逐步替换。
class ChatPage extends StatelessWidget {
  /// 对话话题标题（从上一个页面传入）
  final String topic;

  /// 构造函数
  ///
  /// Key 使用 super 传递，让 Flutter 框架能正确管理 Widget 标识。
  /// required 确保调用方必须提供 topic 参数。
  const ChatPage({super.key, required this.topic});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(topic)),
      // Center 让内容在屏幕正中间显示
      body: Center(
        child: Column(
          // MainAxisAlignment.center 让 Column 的子元素垂直居中
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // emoji 图标，大号展示
            Text('💭', style: Theme.of(context).textTheme.displayMedium),

            const SizedBox(height: 16),

            // 提示文字
            Text(
              '与 $topic 的深度对话',
              style: Theme.of(context).textTheme.titleMedium,
            ),

            const SizedBox(height: 8),

            // 次要说明
            Text(
              '对话功能即将上线',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
