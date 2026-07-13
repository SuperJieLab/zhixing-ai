import 'package:flutter/foundation.dart';

/// 统一日志工具，release 模式静默，debug 模式输出
class AppLogger {
  const AppLogger._();

  static void info(String tag, String message) {
    if (!kReleaseMode) {
      debugPrint('[$tag] $message');
    }
  }

  static void warn(String tag, String message) {
    if (!kReleaseMode) {
      debugPrint('⚠️ [$tag] $message');
    }
  }

  static void error(String tag, String message, [Object? error, StackTrace? stack]) {
    if (!kReleaseMode) {
      debugPrint('[$tag] $message${error != null ? ': $error' : ''}');
      if (stack != null) {
        debugPrint(stack.toString());
      }
    }
  }
}
