import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/logger.dart';
import 'package:zhixing_ai/core/services/push_service.dart';

/// 解析服务端推送消息（纯函数，便于单测）
PushMessage? parsePushMessage(String raw) {
  try {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    if (map['type'] != 'push') return null;
    return PushMessage(map['title'] ?? '', map['body'] ?? '');
  } catch (_) {
    return null;
  }
}

/// 构建 WS 连接地址（纯函数，便于单测）
String buildWsUrl(String token) =>
    '${AppConstants.serverWsUrl}/ws?token=${Uri.encodeQueryComponent(token)}';

class PushMessage {
  final String title;
  final String body;
  PushMessage(this.title, this.body);
}

typedef PushHandler = void Function(String title, String body);

/// 客户端 WS 连接服务：连接 / 监听 / 重连 / 派发
///
/// 【职责】维护一条到服务端的 WebSocket 长连接，接收服务端主动下发的站内推送
/// （{type:'push',title,body,ts}），并派发给注册的 handler（UI 层据此弹应用内横幅）。
///
/// 【在架构中的位置】
///   main.dart → PushSocketService.instance.connect()（App 启动后调用）
///   handler（main.dart 注册）→ 弹 SnackBar 横幅
///
/// 【容错】连接失败/断开自动 5s 重连；connect 有重入守卫避免重复 socket 泄漏。
class PushSocketService {
  static final PushSocketService instance = PushSocketService._();
  PushSocketService._();

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  final List<PushHandler> _handlers = [];
  Timer? _reconnectTimer;
  bool _disposed = false;
  bool _connecting = false;

  void addHandler(PushHandler h) => _handlers.add(h);

  Future<void> connect() async {
    if (_disposed || _channel != null || _connecting) return;
    _connecting = true;
    try {
      final token = await PushService().getToken();
      if (_disposed) return;
      if (token == null) {
        AppLogger.info('PushWS', 'token 为空，跳过连接');
        return;
      }
      final channel = WebSocketChannel.connect(Uri.parse(buildWsUrl(token)));
      _channel = channel;
      _sub = channel.stream.listen(
        _onMessage,
        onDone: _onDisconnect,
        onError: (_) => _onDisconnect(),
      );
      AppLogger.info('PushWS', '已连接');
    } catch (e) {
      AppLogger.info('PushWS', '连接失败: $e');
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  void _onMessage(dynamic message) {
    final msg = parsePushMessage(message.toString());
    if (msg == null) return;
    for (final h in _handlers) {
      h(msg.title, msg.body);
    }
  }

  void _onDisconnect() {
    if (_channel == null) return;
    _sub?.cancel();
    _sub = null;
    _channel = null;
    AppLogger.info('PushWS', '连接断开，5s 后重连');
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), connect);
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
  }
}
