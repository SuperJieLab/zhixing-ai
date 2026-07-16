import 'package:flutter/material.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/dashboard/dashboard_page.dart';

/// Socratic AI 根组件
///
/// 配置 MaterialApp 的三大要素：
/// - **theme**：全局主题（配色、字体、卡片样式——见 AppTheme.lightTheme）
/// - **home**：首页（TopicSelectionPage）
/// - **debugShowCheckedModeBanner**：关闭调试横幅（右上角的 "DEBUG" 标签）
///
/// ## MaterialApp 是什么
/// MaterialApp 是 Flutter 的最高层配置 Widget，负责：
/// - 应用路由（Navigator）
/// - 主题（ThemeData）
/// - 国际化配置
/// - 调试横幅开关
///
/// 一个 Flutter App 只有一个 MaterialApp。
class SocraticApp extends StatelessWidget {
  const SocraticApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // 应用标题（显示在 Android 任务切换器中）
      title: 'Socratic AI',

      // 关闭右上角的 "DEBUG" 横幅
      debugShowCheckedModeBanner: false,

      // 应用全局主题——所有页面的默认配色、字体等
      // 各个页面可以通过 Theme.of(context) 访问
      theme: AppTheme.lightTheme,

      // 首页：大局观面板
      home: const DashboardPage(),
    );
  }
}
