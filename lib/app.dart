import 'package:flutter/material.dart';
import 'package:zhixing_ai/core/ui/route_observer.dart';
import 'package:zhixing_ai/core/ui/theme.dart';
import 'package:zhixing_ai/features/dashboard/dashboard_page.dart';

/// 知行AI 根组件
class ZhixingApp extends StatelessWidget {
  const ZhixingApp({super.key, this.navigatorKey});

  /// 全局 Navigator key（由 main.dart 注入）
  ///
  /// 供非 Widget 层（站内推送回调）获取 BuildContext 弹 SnackBar。
  /// MaterialApp 内部 ScaffoldMessenger 是 Navigator 的祖先，
  /// 因此 ScaffoldMessenger.of(navigatorKey.currentContext) 可正常解析。
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '知行AI',

      navigatorKey: navigatorKey,

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
