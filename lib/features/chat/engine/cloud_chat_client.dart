import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/models/chat_models.dart';
import 'package:zhixing_ai/core/models/dashboard_models.dart';
import 'package:zhixing_ai/features/chat/engine/chat_client.dart';
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

/// 云端对话客户端，实现 [ChatClient]
///
/// 通过 HTTP SSE 对接服务端 /api/chat 接口，与 [LocalChatClient] 共享同一
/// [ChatClient] 契约（云端显式接收完整历史，窗口裁剪后由服务端拼装上下文）。
///
/// 关键约束：
///   - UTF-8 跨 chunk 边界安全：对原始字节流使用 [utf8.decoder] 转换（而非逐 chunk 解码），
///     避免多字节 CJK 字符被 TCP 拆分到两个 chunk 时乱码。
///   - 每次请求创建全新 [CancelToken] 并缓存到字段，供 [stop] 随时取消。
///   - [stop] 通过取消底层 [StreamSubscription] 真正中断正在流式的响应体（仅取消
///     CancelToken 只能在请求建立阶段生效，对已进入响应体的流无效）。
///   - 服务端按帧下发 `{"delta":"..."}` / `{"error":"..."}` / `[DONE]`，[SseBuffer] 负责切帧。
class CloudChatClient implements ChatClient {
  late final Dio _dio;

  /// 帧间空闲超时：任意两帧（解码后的 chunk）之间的间隔超过该值即视为服务端卡死，
  /// 向上抛 [TimeoutException]，交由上层（ChatProvider）决定降级策略。
  ///
  /// 注意这是「帧间空闲」而非「总时长」语义：流式过程中只要持续有数据到达就不会触发，
  /// 仅当服务端长时间（默认 10s）不再下发任何字节时才超时。触发后由上层决定降级。
  final Duration _frameTimeout;

  /// initialize 暂存的已有目标（② 落地后随请求体发送、由服务端拼装系统提示词，
  /// 与本地人设对等；当前仅占位，不影响请求）。
  // ignore: unused_field
  List<Goal> _pendingGoals = const [];

  /// 历史窗口大小：尾部用户消息之外最多携带的上下文条数（自 Provider._sendCloud 迁入）。
  static const _windowSize = 10;

  CancelToken? _cancelToken;
  StreamSubscription<void>? _bodySubscription;
  StreamController<String>? _activeController;

  /// [baseUrl] 默认取 [AppConstants.serverBaseUrl]，测试时可注入 mock 服务端地址。
  /// [frameTimeout] 帧间空闲超时（默认 10s），详见 [_frameTimeout]。
  CloudChatClient({
    String? baseUrl,
    Duration frameTimeout = const Duration(seconds: 10),
  })  : _frameTimeout = frameTimeout, // ignore: prefer_initializing_formals
        _dio = Dio(BaseOptions(
          baseUrl: baseUrl ?? AppConstants.serverBaseUrl,
          responseType: ResponseType.stream,
          connectTimeout: const Duration(seconds: 10),
        ));

  @override
  bool get isReady => true;

  @override
  Future<bool> initialize({List<Goal> existingGoals = const []}) async {
    // 云端模式无引擎可加载，恒就绪；goals 暂存，② 落地后随请求体发送。
    _pendingGoals = existingGoals;
    return true;
  }

  /// 流式生成回复
  ///
  /// [history] 为完整对话历史（尾部为本轮新用户消息，含 round==0 欢迎语）。
  /// 窗口构造（自 ChatProvider._sendCloud 迁入）：尾部消息之外的部分过滤
  /// round==0 欢迎语（其读起来像助手指令而非真实对话），超过 [_windowSize]
  /// 取尾部 10 条，再附上尾部消息随请求体发送。
  /// 逐段 yield 服务端的 `delta` 文本；遇到 `error` 帧或网络异常则抛异常，
  /// 由上层（ChatProvider）捕获并决定降级策略。
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

  /// SSE 内核（签名 [ChatClient] 化前即存在，行为不变）
  Stream<String> _generate(
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
    // 帧间空闲超时：叠加在解码流之上（每帧到达都会重置计时，单个大 chunk 不受影响）。
    // 超时无 onTimeout 处理 → 抛 TimeoutException 作为 stream 的错误事件，
    // 由下方 onError 透传给消费方；cancel 该订阅会向下转发取消底层响应体订阅。
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
      // 取消订阅后 listen 不会触发 onDone，需主动关闭以结束消费方的 await for。
      controller.close();
    }
    _activeController = null;
  }

  /// 释放底层 Dio 实例（ChatProvider.dispose 调用）
  @override
  void dispose() {
    _activeController?.close();
    _activeController = null;
    _bodySubscription?.cancel();
    _dio.close(force: true);
  }
}
