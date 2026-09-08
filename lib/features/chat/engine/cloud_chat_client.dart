import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/features/chat/engine/sse_parser.dart';

/// 云端对话模式
///
/// 与 [ChatMode.local]（本地 LLM 引擎）对应，使用 [CloudChatClient] 走服务端 SSE。
enum ChatMode {
  /// 本地引擎（默认，离线可用）
  local,

  /// 云端 SSE 流式对话
  cloud,
}

/// 云端对话客户端
///
/// 通过 HTTP SSE 对接服务端 /api/chat 接口，提供与 [StrategistPrompter] 对齐的
/// 流式 [generateResponse] 接口（除参数形状：云端显式接收完整历史，由服务端拼装上下文）。
///
/// 关键约束：
///   - UTF-8 跨 chunk 边界安全：对原始字节流使用 [utf8.decoder] 转换（而非逐 chunk 解码），
///     避免多字节 CJK 字符被 TCP 拆分到两个 chunk 时乱码。
///   - 每次请求创建全新 [CancelToken] 并缓存到字段，供 [stop] 随时取消。
///   - [stop] 通过取消底层 [StreamSubscription] 真正中断正在流式的响应体（仅取消
///     CancelToken 只能在请求建立阶段生效，对已进入响应体的流无效）。
///   - 服务端按帧下发 `{"delta":"..."}` / `{"error":"..."}` / `[DONE]`，[SseBuffer] 负责切帧。
class CloudChatClient {
  final String _baseUrl;
  late final Dio _dio;

  CancelToken? _cancelToken;
  StreamSubscription<void>? _bodySubscription;
  StreamController<String>? _activeController;

  /// [baseUrl] 默认取 [AppConstants.serverBaseUrl]，测试时可注入 mock 服务端地址。
  CloudChatClient({String? baseUrl})
      : _baseUrl = baseUrl ?? AppConstants.serverBaseUrl {
    _dio = Dio(BaseOptions(
      baseUrl: _baseUrl,
      responseType: ResponseType.stream,
      connectTimeout: const Duration(seconds: 10),
    ));
  }

  /// 流式生成回复
  ///
  /// [messages] 为完整对话历史（含本轮新用户消息），由调用方按窗口构造。
  /// 逐段 yield 服务端的 `delta` 文本；遇到 `error` 帧或网络异常则抛异常，
  /// 由上层（ChatProvider）捕获并决定降级策略。
  Stream<String> generateResponse(
      List<({String role, String content})> messages) {
    // 每次请求重建 CancelToken，否则第二次调用会沿用已取消的旧 token。
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
    };

    Response<ResponseBody> resp;
    try {
      resp = await _dio.post<ResponseBody>(
        '/api/chat',
        data: body,
        cancelToken: cancelToken,
      );
    } on DioException catch (e) {
      // 连接被拒 / 超时 / 取消 / 4xx·5xx：原样上抛，交由 Provider 处理并记录日志。
      // stop() 可能在请求建立阶段就已关闭 controller，此时再 addError 会抛 StateError。
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

    final buffer = SseBuffer();
    final subscription = stream.cast<List<int>>().transform(utf8.decoder).listen(
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
          // JSON 解析等异常透传给消费方。
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

  /// 向可能已关闭的 controller 安全投递错误
  ///
  /// stop() 会在请求建立阶段就关闭 controller（覆盖 setup 期取消），此时
  /// addError 会抛 StateError 并成为未处理异步异常——此处在关闭态静默丢弃。
  void _safeError(StreamController<String> controller, Object error) {
    if (!controller.isClosed) {
      controller.addError(error);
    }
  }

  /// 中止当前进行中的请求
  ///
  /// 取消底层响应体订阅 → 停止读取 → 关闭 socket → 服务端感知客户端断开并中止上游
  /// （见 Task 3 取消传播）；同时取消 token（覆盖请求建立阶段的中断）。
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
      // 取消订阅后 listen 不会触发 onDone，需主动关闭以结束消费方的 await for。
      controller.close();
    }
    _activeController = null;
  }

  /// 释放底层 Dio 实例（ChatProvider.dispose 调用）
  void dispose() {
    _activeController?.close();
    _activeController = null;
    _bodySubscription?.cancel();
    _dio.close(force: true);
  }
}
