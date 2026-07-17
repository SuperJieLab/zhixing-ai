import 'package:flutter/material.dart';
import 'package:socratic_ai/core/route_observer.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/dashboard/dashboard_page.dart';

/// Socratic AI 根组件
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

      navigatorObservers: [routeObserver],

      // 首页：Dashboard 面板
      home: const DashboardPage(),
    );
  }
}
