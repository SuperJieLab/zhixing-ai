import 'package:flutter/material.dart';

/// SnackBar 防抖工具
///
/// 防止用户反复操作导致同一 SnackBar 频繁弹出。
/// 按消息文本做 keyed throttle——同一消息在 [throttleMs] 内只放行一次，
/// 不同消息互不干扰。
class SnackBarThrottle {
  static final Map<String, int> _lastAtMap = {};

  /// 显示一个带防抖的 SnackBar
  ///
  /// 相同 [message] 在 [throttleMs] 毫秒内的重复调用会被忽略。
  /// 不同消息之间独立计时，互不阻塞。
  /// 显示前会先调用 [ScaffoldMessengerState.clearSnackBars] 清除队列中的残余。
  static void show(
    BuildContext context,
    String message, {
    int throttleMs = 500,
    SnackBarBehavior behavior = SnackBarBehavior.floating,
    Duration duration = const Duration(seconds: 3),
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastAtMap[message] ?? 0;
    if (now - last < throttleMs) return;
    _lastAtMap[message] = now;

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
