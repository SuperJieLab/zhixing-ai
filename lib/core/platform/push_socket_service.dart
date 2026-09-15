import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/logger.dart';
import 'package:zhixing_ai/core/platform/push_service.dart';

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

/// 客户端 WS 长连接：接收服务端站内推送（{type:'push',...}）并派发给 handler。
/// 连接失败/断开自动指数退避重连（5s 起 ×2 封顶 60s，连上重置）；
/// connect 有重入守卫避免重复 socket 泄漏。
class PushSocketService {
  static final PushSocketService instance = PushSocketService._();
  PushSocketService._();

  static const Duration _baseReconnectDelay = Duration(seconds: 5);
  static const Duration _maxReconnectDelay = Duration(seconds: 60);
  Duration _reconnectDelay = _baseReconnectDelay;

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
      final token = await PushService.instance.getToken();
      if (_disposed) return;
      if (token == null) {
        AppLogger.info('PushWS', 'token 为空，跳过连接');
        return;
      }
      final channel = WebSocketChannel.connect(Uri.parse(buildWsUrl(token)));
      _channel = channel;
      // web_socket_channel 2.4+：连接失败错误经 channel.ready 传播，
      // 不 await 会导致 Unhandled Exception，且无法感知"真正连上"的时刻。
      await channel.ready;
      if (_disposed) {
        await channel.sink.close();
        return;
      }
      _sub = channel.stream.listen(
        _onMessage,
        onDone: _onDisconnect,
        onError: (_) => _onDisconnect(),
      );
      _reconnectDelay = _baseReconnectDelay; // 连上后重置退避
      AppLogger.info('PushWS', '已连接');
    } catch (e) {
      _channel = null;
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
    AppLogger.info('PushWS', '连接断开');
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    AppLogger.info('PushWS', '${_reconnectDelay.inSeconds}s 后重连');
    _reconnectTimer = Timer(_reconnectDelay, () {
      // 指数退避：失败越多次重连间隔越长，封顶 60s，避免服务端不在线时刷屏
      final doubled = _reconnectDelay * 2;
      _reconnectDelay =
          doubled > _maxReconnectDelay ? _maxReconnectDelay : doubled;
      connect();
    });
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
