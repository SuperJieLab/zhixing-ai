import 'package:flutter/material.dart';

/// 全局路由观察者
///
/// 供 RouteAware 组件监听路由变化。DashboardPage 用它在返回时自动刷新数据。
final routeObserver = RouteObserver<ModalRoute<void>>();
