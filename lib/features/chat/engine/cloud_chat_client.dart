import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
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

/// 云端对话客户端：BYOK 直连用户配置的 OpenAI 兼容端点（不经过本应用服务端）。
///
/// 坑位备忘：
///   - 必须用 [utf8.decoder] 转换原始字节流，多字节 CJK 字符可能被 TCP 拆到两个 chunk；
///   - [stop] 要取消响应体订阅——仅取消 CancelToken 对已进入响应体的流无效。
class CloudChatClient implements ChatClient {
  late final Dio _dio;

  /// API Key（Bearer 认证），仅存本机、随请求头发送。
  final String _apiKey;

  /// 模型名（自由文本，OpenAI 兼容端点按此路由）。
  final String _modelName;

  /// 帧间空闲超时（非总时长）：超时抛 [TimeoutException] 交上层降级。
  final Duration _frameTimeout;

  /// initialize 暂存的已有目标，请求时拼进 system 消息（与本地人设逐字一致）。
  List<Goal> _pendingGoals = const [];

  /// 本地/云端共享的唯一人设出处。
  final ConversationStrategy _strategy;

  /// 尾部用户消息之外最多携带的上下文条数。
  static const _windowSize = 10;

  CancelToken? _cancelToken;
  StreamSubscription<void>? _bodySubscription;
  StreamController<String>? _activeController;

  /// [baseUrl] 为 OpenAI 兼容端点根地址（容忍尾斜杠），客户端拼 `/chat/completions`。
  CloudChatClient({
    required String baseUrl,
    required String apiKey,
    required String modelName,
    Duration frameTimeout = const Duration(seconds: 10),
    ConversationStrategy? strategy,
  })  : _apiKey = apiKey, // ignore: prefer_initializing_formals
        _modelName = modelName, // ignore: prefer_initializing_formals
        _frameTimeout = frameTimeout, // ignore: prefer_initializing_formals
        _strategy = strategy ?? ConversationStrategy(),
        _dio = Dio(BaseOptions(
          // 容忍尾斜杠：用户从厂商文档复制的根地址形态不保证无尾斜杠
          baseUrl: baseUrl.replaceAll(RegExp(r'/+$'), ''),
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
  /// HTTP 非 200 或网络异常原样上抛，由上层决定降级策略。
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
      'model': _modelName,
      'messages': [
        // 人设唯一出处：与本地模式共享同一份 system 提示词（含 goals 注入）。
        {
          'role': 'system',
          'content': _strategy.buildSystemPrompt(existingGoals: _pendingGoals),
        },
        ...messages.map((m) => {'role': m.role, 'content': m.content}),
      ],
      'stream': true,
      // temperature/max_tokens 等参数 MVP 不下发，用厂商默认。
    };

    Response<ResponseBody> resp;
    try {
      resp = await _dio.post<ResponseBody>(
        '/chat/completions',
        data: body,
        cancelToken: cancelToken,
        options: Options(headers: {'Authorization': 'Bearer $_apiKey'}),
      );
    } on DioException catch (e) {
      // 非 2xx 也走 DioException：带上 status 便于用户定位（401/429/欠费等）。
      final status = e.response?.statusCode;
      _safeError(
        controller,
        Exception('云端 API 请求失败${status != null ? '（HTTP $status）' : ''}'
            ': ${e.message ?? e.type.name}'),
      );
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
            final delta = _extractDelta(json);
            if (delta != null && delta.isNotEmpty) {
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

  /// 取 OpenAI 流式增量：`choices[0].delta.content`。
  /// 缺 choices / delta 只有 role / finish_reason 帧等一律返回 null（跳过）。
  static String? _extractDelta(Map<String, dynamic> json) {
    final choices = json['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final first = choices.first;
    if (first is! Map<String, dynamic>) return null;
    final delta = first['delta'];
    if (delta is! Map<String, dynamic>) return null;
    final content = delta['content'];
    return content is String ? content : null;
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

  /// 中止进行中请求：取消响应体订阅（直连下即断开厂商 socket）+ CancelToken。
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
