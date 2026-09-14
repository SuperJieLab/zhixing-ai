import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhixing_ai/core/logger.dart';

// ============================================================
// PushService — 推送服务（端侧）
// ============================================================
//
// 【这个文件做什么】
// 管理设备的 FCM（Firebase Cloud Messaging）推送 token。
// App 启动时自动获取 token，后续 SyncService 用它作为设备标识上报到服务端。
//
// 【在架构中的位置】
//   main.dart → PushService().initialize()（App 启动时调用，不阻塞启动）
//   SyncService → PushService().getToken()（同步前获取设备 token）
//
// 【两种运行模式】
//   - Firebase 已配置：正常获取 FCM token，App 能收到真实推送
//   - Firebase 未配置：catch 异常 → 生成 "mock_token_xxx" 作为占位符
//     （MVP 阶段：没有 Firebase 项目时 App 照常运行，只是推送走 console.log）
//
// 【面试可聊】
//   - 为什么用单例？→ token 全局唯一，多处需要（main.dart、SyncService）
//   - Firebase 未配置时为什么降级而非崩溃？→ 渐进式集成：先跑通链路，再加 Firebase
//   - onTokenRefresh 做什么？→ token 可能因 App 重装/清数据而变，监听刷新保证同步
//
// 【依赖】
//   - firebase_messaging（FCM SDK）
//   - firebase_core（Firebase 初始化，在 main.dart 中）

class PushService {
  static final PushService _instance = PushService._();
  factory PushService() => _instance;
  PushService._();

  /// mock token 的持久化键（修复：原实现带时间戳，每次重启漂移，
  /// 服务端同步 store 里的旧设备数据成孤儿、cron 永远扫到死 token）。
  static const String _kMockToken = 'mock_push_token';

  String? _token;

  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    try {
      final messaging = FirebaseMessaging.instance;

      // 请求通知权限（iOS 需要）
      await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      // 获取 FCM token
      _token = await messaging.getToken();
      AppLogger.info('Push', 'FCM token: ${_token?.substring(0, _token!.length > 12 ? 12 : _token!.length)}...');

      // 监听 token 刷新
      messaging.onTokenRefresh.listen((newToken) {
        _token = newToken;
        AppLogger.info('Push', 'FCM token refreshed');
      });
    } catch (e) {
      // Firebase 未配置时降级为 Mock token（跨重启稳定）
      _token = await _stableMockToken();
      AppLogger.info('Push', 'FCM 不可用，使用 Mock token: $_token');
    }
  }

  /// 稳定的 mock 设备标识：首次生成后持久化，重启复用（等价真实 FCM
  /// token 的「重启不变」特性）。持久化不可用时退回一次性时间戳（旧行为）。
  Future<String> _stableMockToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = prefs.getString(_kMockToken);
      if (existing != null && existing.isNotEmpty) return existing;
      final token =
          'mock_token_${DateTime.now().millisecondsSinceEpoch}';
      await prefs.setString(_kMockToken, token);
      return token;
    } catch (e) {
      AppLogger.warn('Push', 'mock token 持久化失败（退回一次性标识）: $e');
      return 'mock_token_${DateTime.now().millisecondsSinceEpoch}';
    }
  }

  /// 获取当前设备推送 token（首次调用时自动初始化）
  Future<String?> getToken() async {
    if (_token == null) await initialize();
    return _token;
  }
}
