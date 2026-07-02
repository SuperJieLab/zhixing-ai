import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:socratic_ai/app.dart';
import 'package:socratic_ai/features/topics/providers/topic_provider.dart';

/// 应用入口
///
/// Dart 程序的起点——main() 函数。
/// Flutter 的约定：main() 中只做两件事：
/// 1. 创建 Provider（依赖注入）
/// 2. 启动 App（runApp）
///
/// ## MultiProvider
/// 当一个 App 有多个 Provider 时，用 MultiProvider 嵌套它们。
/// 目前只有 TopicProvider，后续 Day 5 加入后端后可能新增更多。
///
/// ## 为什么 Provider 在 runApp 外面？
/// Provider 必须挂在 MaterialApp 的上层，这样 App 内所有页面
/// 都能通过 context.watch/read 访问到它。
void main() {
  runApp(
    // MultiProvider 包裹整个 App，提供全局状态管理
    MultiProvider(
      providers: [
        // TopicProvider：管理用户在首页选择的话题
        ChangeNotifierProvider(create: (_) => TopicProvider()),
      ],
      child: const SocraticApp(),
    ),
  );
}
