import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/data/models/dashboard_models.dart';
import 'package:zhixing_ai/features/chat/engine/chat_client.dart';
import 'package:zhixing_ai/features/chat/engine/conversation_strategy.dart';
import 'package:zhixing_ai/features/chat/engine/sse_parser.dart';

/// 云端对话模式
enum ChatMode {
  local,
  cloud,
}

/// 云端对话客户端：HTTP SSE 对接服务端 /api/chat。
///
/// 坑位备忘：
///   - 必须用 [utf8.decoder] 转换原始字节流，多字节 CJK 字符可能被 TCP 拆到两个 chunk；
///   - [stop] 要取消响应体订阅——仅取消 CancelToken 对已进入响应体的流无效。
class CloudChatClient implements ChatClient {
  late final Dio _dio;

  /// 帧间空闲超时（非总时长）：超时抛 [TimeoutException] 交上层降级。
  final Duration _frameTimeout;

  /// initialize 暂存的已有目标，请求时拼进 systemPrompt（与本地人设逐字一致）。
  List<Goal> _pendingGoals = const [];

  /// 本地/云端共享的唯一人设出处。
  final ConversationStrategy _strategy;

  /// 尾部用户消息之外最多携带的上下文条数。
  static const _windowSize = 10;

  CancelToken? _cancelToken;
  StreamSubscription<void>? _bodySubscription;
  StreamController<String>? _activeController;

  CloudChatClient({
    String? baseUrl,
    Duration frameTimeout = const Duration(seconds: 10),
    ConversationStrategy? strategy,
  })  : _frameTimeout = frameTimeout, // ignore: prefer_initializing_formals
        _strategy = strategy ?? ConversationStrategy(),
        _dio = Dio(BaseOptions(
          baseUrl: baseUrl ?? AppConstants.serverBaseUrl,
          responseType: ResponseType.stream,
          connectTimeout: const Duration(seconds: 10),
        ));

  @override
  bool get isReady => true;

  @override
  Future<bool> initialize({List<Goal> existingGoals = const []}) async {
    _pendingGoals = existingGoals;
    return true;
  }

  /// [history] 为完整历史（尾部为本轮新用户消息）。
  /// 窗口：尾部消息之外滤 round==0 欢迎语、取尾 [_windowSize] 条，再附尾部消息。
  /// `error` 帧或网络异常原样上抛，由上层决定降级策略。
  @override
  Stream<String> generateResponse(List<ChatMessage> history) {
    if (history.isEmpty) {
      throw ArgumentError('history 不能为空');
    }
    final tail = history.last;
    var window = history
        .take(history.length - 1)
        .where((m) => m.round != 0)
        .toList();
    if (window.length > _windowSize) {
      window = window.sublist(window.length - _windowSize);
    }
    final payload = window
        .map((m) => (
              role: m.role == MessageRole.user ? 'user' : 'assistant',
              content: m.content,
            ))
        .toList();
    payload.add((
      role: tail.role == MessageRole.user ? 'user' : 'assistant',
      content: tail.content,
    ));
    return _generate(payload);
  }

  Stream<String> _generate(
      List<({String role, String content})> messages) {
    // 每次重建：沿用旧 token 会在第二次调用时直接命中已取消状态。
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;

    final controller = StreamController<String>();
    _activeController = controller;

    unawaited(_runRequest(messages, cancelToken, controller));

    return controller.stream;
  }

  Future<void> _runRequest(
    List<({String role, String content})> messages,
    CancelToken cancelToken,
    StreamController<String> controller,
  ) async {
    final body = {
      'messages': messages
          .map((m) => {'role': m.role, 'content': m.content})
          .toList(),
      // 客户端拼装人设（含 goals）；服务端有则用之，缺省回落内置兜底。
      'systemPrompt': _strategy.buildSystemPrompt(existingGoals: _pendingGoals),
    };

    Response<ResponseBody> resp;
    try {
      resp = await _dio.post<ResponseBody>(
        '/api/chat',
        data: body,
        cancelToken: cancelToken,
      );
    } on DioException catch (e) {
      // stop() 可能已关 controller，addError 会抛 StateError，故走 _safeError。
      _safeError(controller, e);
      await controller.close();
      _clearActive();
      return;
    }

    final stream = resp.data?.stream;
    if (stream == null) {
      _safeError(controller, Exception('云端返回空响应流'));
      await controller.close();
      _clearActive();
      return;
    }

    // 帧间空闲超时：超时作为错误事件透传给消费方。
    final buffer = SseBuffer();
    final subscription = stream
        .cast<List<int>>()
        .transform(utf8.decoder)
        .timeout(_frameTimeout)
        .listen(
      (chunkText) {
        try {
          for (final data in buffer.feed(chunkText)) {
            final json = jsonDecode(data) as Map<String, dynamic>;

            final error = json['error'];
            if (error != null) {
              _safeError(controller, Exception('云端对话失败: $error'));
              controller.close();
              return;
            }

            final delta = json['delta'];
            if (delta is String && delta.isNotEmpty) {
              controller.add(delta);
            }
          }
        } catch (e) {
          _safeError(controller, e);
          controller.close();
        }
      },
      onError: (Object e) {
        _safeError(controller, e);
        controller.close();
      },
      onDone: () {
        controller.close();
        _clearActive();
      },
    );
    _bodySubscription = subscription;
  }

  void _clearActive() {
    _bodySubscription = null;
    if (_activeController != null && _activeController!.isClosed) {
      _activeController = null;
    }
  }

  /// controller 可能已被 stop() 关闭，此时静默丢弃（否则 StateError 成未处理异常）。
  void _safeError(StreamController<String> controller, Object error) {
    if (!controller.isClosed) {
      controller.addError(error);
    }
  }

  /// 中止进行中请求：取消响应体订阅（服务端感知断开 → 中止上游）+ CancelToken。
  @override
  void stop() {
    final sub = _bodySubscription;
    if (sub != null) {
      sub.cancel();
    }
    _bodySubscription = null;

    final token = _cancelToken;
    if (token != null && !token.isCancelled) {
      token.cancel('用户中止云端对话');
    }

    final controller = _activeController;
    if (controller != null && !controller.isClosed) {
      // 取消订阅不会触发 onDone，需主动关闭结束消费方的 await for。
      controller.close();
    }
    _activeController = null;
  }

  @override
  void dispose() {
    _activeController?.close();
    _activeController = null;
    _bodySubscription?.cancel();
    _dio.close(force: true);
  }
}
