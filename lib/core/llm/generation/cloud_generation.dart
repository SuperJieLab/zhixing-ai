import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/context/context_assembly.dart';
import 'package:zhixing_ai/core/llm/generation/generation.dart';
import 'package:zhixing_ai/core/llm/generation/sse_parser.dart';

/// 云端交付实现：BYOK 直连用户配置的 OpenAI 兼容端点（不经过本应用服务端）。
///
/// 只负责「把装配好的上下文送进模型并取回文本流」：HTTP 请求体、SSE 增量收敛、
/// 取消/超时。上下文装配（过滤 / 装窗 / 压缩）与服务编排都不属于本类。
///
/// 坑位备忘：
///   - 必须用 [utf8.decoder] 转换原始字节流，多字节 CJK 字符可能被 TCP 拆到两个 chunk；
///   - [stop] 要取消响应体订阅——仅取消 CancelToken 对已进入响应体的流无效。
///   - 云端**不剥 think**（与端侧不一致是既有的有意识选择；是否统一见设计 §10.1 #5）。
class CloudGeneration implements ChatGeneration {
  late final Dio _dio;

  /// API Key（Bearer 认证），仅存本机、随请求头发送。
  final String _apiKey;

  /// 模型名（自由文本，OpenAI 兼容端点按此路由）。
  final String _modelName;

  /// 帧间空闲超时（非总时长）：超时抛 [TimeoutException] 交上层降级。
  final Duration _frameTimeout;

  CancelToken? _cancelToken;
  StreamSubscription<void>? _bodySubscription;
  StreamController<String>? _activeController;

  /// [baseUrl] 为 OpenAI 兼容端点根地址（容忍尾斜杠），客户端拼 `/chat/completions`。
  /// [dio] 仅测试注入。
  CloudGeneration({
    required String baseUrl,
    required String apiKey,
    required String modelName,
    Duration frameTimeout = const Duration(seconds: 10),
    Dio? dio,
  })  : _apiKey = apiKey, // ignore: prefer_initializing_formals
        _modelName = modelName, // ignore: prefer_initializing_formals
        _frameTimeout = frameTimeout, // ignore: prefer_initializing_formals
        _dio = dio ??
            Dio(BaseOptions(
              // 容忍尾斜杠：用户从厂商文档复制的根地址形态不保证无尾斜杠
              baseUrl: baseUrl.replaceAll(RegExp(r'/+$'), ''),
              responseType: ResponseType.stream,
              connectTimeout: const Duration(seconds: 10),
            ));

  @override
  bool get isReady => true;

  /// 云端无本地资源需加载（配置校验在服务入口完成）。
  @override
  Future<void> ensureReady() async {}

  /// [assembled] 由服务装配（过滤 round==0 + 装窗 + 必要时压缩）。
  /// HTTP 非 200 或网络异常原样上抛，由上层决定降级策略。
  @override
  Stream<String> deliver(
    AssembledContext assembled, {
    required String systemPrompt,
    bool nudgeTail = true,
  }) {
    final payload = assembled.messages
        .map((m) => (
              role: m.role == MessageRole.user ? 'user' : 'assistant',
              content: m.content,
            ))
        .toList();
    return _generate(
      payload,
      systemPrompt: systemPrompt,
      summaryCard: assembled.summaryCard,
    );
  }

  /// 云端无会话态：无需预置（契约对称的空实现）。
  @override
  void prime(
    AssembledContext assembled, {
    required String systemPrompt,
    bool nudgeTail = true,
  }) {}

  Stream<String> _generate(
    List<({String role, String content})> messages, {
    required String systemPrompt,
    required String? summaryCard,
  }) {
    // 每次重建：沿用旧 token 会在第二次调用时直接命中已取消状态。
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;

    final controller = StreamController<String>();
    _activeController = controller;

    unawaited(_runRequest(
      messages,
      cancelToken,
      controller,
      systemPrompt: systemPrompt,
      summaryCard: summaryCard,
    ));

    return controller.stream;
  }

  Future<void> _runRequest(
    List<({String role, String content})> messages,
    CancelToken cancelToken,
    StreamController<String> controller, {
    required String systemPrompt,
    required String? summaryCard,
  }) async {
    final body = {
      'model': _modelName,
      'messages': [
        // 人设由业务提供（唯一出处是业务侧的人设构建器）。
        {'role': 'system', 'content': systemPrompt},
        // 摘要卡（如有）紧随人设之后：同为 system 消息，不进对话 role 序列。
        if (summaryCard != null) {'role': 'system', 'content': summaryCard},
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
      _failActive(
        controller,
        Exception('云端 API 请求失败${status != null ? '（HTTP $status）' : ''}'
            ': ${e.message ?? e.type.name}'),
        null,
      );
      return;
    }

    final stream = resp.data?.stream;
    if (stream == null) {
      _failActive(controller, Exception('云端返回空响应流'), null);
      return;
    }

    // 帧间空闲超时：超时作为错误事件透传给消费方。
    final buffer = SseBuffer();
    StreamSubscription<void>? sub;
    sub = stream
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
          _failActive(controller, e, sub);
        }
      },
      onError: (Object e) {
        // 超时 / 网络错误：timeout 不取消源订阅，必须显式 cancel 断开连接，
        // 否则 HTTP 连接悬挂到服务端断开为止。
        _failActive(controller, e, sub);
      },
      onDone: () {
        controller.close();
        _clearActive();
      },
    );
    _bodySubscription = sub;
  }

  /// 错误收尾：透传错误 + 取消响应体订阅 + 清理活动引用（幂等，可重复进入）。
  void _failActive(
    StreamController<String> controller,
    Object error,
    StreamSubscription<void>? sub,
  ) {
    _safeError(controller, error);
    unawaited(sub?.cancel());
    if (identical(_bodySubscription, sub)) _bodySubscription = null;
    if (!controller.isClosed) controller.close();
    if (identical(_activeController, controller)) _activeController = null;
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
