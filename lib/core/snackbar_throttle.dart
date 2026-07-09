import 'package:flutter/material.dart';

/// SnackBar 防抖工具
///
/// 防止用户反复操作导致同一 SnackBar 频繁弹出。
/// 全局共享一个时间戳——任意两处 SnackBar 展示间隔小于 [throttleMs] 时后一个被吞掉。
class SnackBarThrottle {
  static int _lastAt = 0;

  /// 显示一个带防抖的 SnackBar
  ///
  /// 与上一个 SnackBar（无论来源）间隔小于 [throttleMs] 毫秒时忽略本次请求。
  /// 显示前会先调用 [ScaffoldMessengerState.clearSnackBars] 清除队列中的残余。
  static void show(
    BuildContext context,
    String message, {
    int throttleMs = 500,
    SnackBarBehavior behavior = SnackBarBehavior.floating,
    Duration duration = const Duration(seconds: 3),
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastAt < throttleMs) return;
    _lastAt = now;

    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: behavior,
        duration: duration,
      ),
    );
  }
}
