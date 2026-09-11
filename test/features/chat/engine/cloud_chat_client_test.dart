import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/data/models/dashboard_models.dart';
import 'package:zhixing_ai/features/chat/engine/cloud_chat_client.dart';
import 'package:zhixing_ai/features/chat/engine/cloud_context_policy.dart';
import 'package:zhixing_ai/features/chat/engine/context_policy.dart';

// 云端对话客户端（BYOK 直连）真实集成测试
//
// 用真实 dart:io HttpServer 起本地 mock OpenAI 兼容 SSE 服务端（127.0.0.1
// 直连），验证 [CloudChatClient] 的关键行为：
//   A. 正常 delta 流按序产出并正常结束；
//   B. [CloudChatClient.stop] 提前终止消费，且服务端在帧未发完时感知到 socket
//      断开（客户端取消 → 连接销毁 → 厂商侧中断）；
//   C. 帧间空闲超时（[TimeoutException]，帧间空闲语义而非总时长）；
//   D. 上下文装配：round==0 欢迎语被过滤、system 首条、尾部用户消息随请求发送；
//   E. 预算内历史全量携带（不再固定取尾 10 条）；
//   F. isReady 恒真、initialize 暂存 goals；
//   G. 请求体：system 人设（含 goals）+ model + Authorization 头；
//   H. 无 goals 时 system 不含目标段；
//   I. HTTP 非 200（401）→ 抛错且含状态码；
//   J. 无 delta.content 的帧（role/finish_reason）被跳过；
//   K. 小预算触发装窗：仅保留保底尾部 + 移出消息进摘要器。
//
// 关键：服务端必须设 `bufferOutput = false`——dart:io HttpResponse 默认缓冲输出，
// 小写入会攒到连接关闭才上线，SSE 增量投递完全失效（曾由此误判为环境代理缓冲）。

const _dummyKey = 'sk-test';
const _dummyModel = 'test-model';

/// 记录调用次数的摘要器 fake：小预算用例中验证「移出消息真的进了摘要器」。
class _FakeSummarizer implements ConversationSummarizer {
  int calls = 0;
  List<ChatMessage> lastEvicted = const [];

  @override
  Future<String> summarize(
      String previousSummary, List<ChatMessage> evicted) async {
    calls++;
    lastEvicted = evicted;
    return '摘要卡正文';
  }
}

/// mock SSE 服务端句柄：端口 + 客户端提前断开的感知信号 + 最近一次请求。
class _MockServer {
  _MockServer(this.server, this.clientDisconnected);
  final HttpServer server;
  final Completer<void> clientDisconnected;

  /// 最近一次收到的请求（供断言 Authorization 等请求头）。
  HttpRequest? lastRequest;

  String get baseUrl => 'http://127.0.0.1:${server.port}';

  Future<void> close() => server.close(force: true);
}

/// 起一个 mock SSE 服务端。
///
/// [onConnected] 在收到 POST 后被调用，拿到响应写出器与请求体（UTF-8 解码后的
/// JSON 字符串）；测试用例自行决定发什么帧、何时停顿。服务端全程感知客户端
/// 是否提前断开（[response.done]）。
Future<_MockServer> _startMock(
  Future<void> Function(HttpResponse resp, _MockServer s, String body)
      onConnected,
) async {
  final server = await HttpServer.bind('127.0.0.1', 0);
  final disconnected = Completer<void>();
  server.listen((req) async {
    // 客户端断开感知（双保险）：
    //   1. response.done 完成（正常关闭或连接终止）；
    //   2. 写帧时 flush 抛错（socket 已死，EPIPE/ECONNRESET）。
    // 注意不能监听 req.socket——会与 req.fold 抢请求体字节。
    unawaited(req.response.done.then(
      (_) {
        if (!disconnected.isCompleted) disconnected.complete();
      },
      onError: (_) {
        if (!disconnected.isCompleted) disconnected.complete();
      },
    ));
    if (req.method != 'POST') {
      req.response
        ..statusCode = 405
        ..close();
      return;
    }
    // 读取请求体（UTF-8 解码，供窗口断言回显）。
    final bodyBytes = await req.fold<List<int>>([], (b, c) => b..addAll(c));
    final body = utf8.decode(bodyBytes);
    req.response
      ..bufferOutput = false // ★ 关闭输出缓冲，否则 SSE 帧攒到 close 才上线
      ..statusCode = 200
      ..headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8')
      ..headers.add('Cache-Control', 'no-cache')
      ..headers.add('Connection', 'keep-alive');
    final s = _MockServer(server, disconnected);
    s.lastRequest = req;
    await onConnected(req.response, s, body);
  });
  return _MockServer(server, disconnected);
}

/// 写一帧并立即 flush（不 flush 会被缓冲，帧无法增量到达）。
/// socket 已死时 flush 抛错 → 通知断开感知。
Future<void> _writeFrame(
  HttpResponse resp,
  String payload,
  Completer<void> disconnected,
) async {
  resp.write('data: $payload\n\n');
  try {
    await resp.flush();
  } catch (_) {
    if (!disconnected.isCompleted) disconnected.complete();
    rethrow;
  }
}

/// OpenAI 格式增量帧：`{"choices":[{"delta":{"content":...}}]}`。
String _openAiDelta(String content) =>
    '{"choices":[{"delta":{"content":${jsonEncode(content)}}}]}';

CloudChatClient _client(
  String baseUrl, {
  Duration? frameTimeout,
  ContextPolicy? policy,
}) =>
    CloudChatClient(
      baseUrl: baseUrl,
      apiKey: _dummyKey,
      modelName: _dummyModel,
      frameTimeout: frameTimeout ?? const Duration(seconds: 10),
      policy: policy,
    );

void main() {
  /// 回显服务端收到的 messages（跳过 system，role:content| 逐帧），供窗口断言。
  Future<void> echoMessages(
    HttpResponse resp,
    _MockServer s,
    String body,
  ) async {
    final msgs =
        (jsonDecode(body) as Map<String, dynamic>)['messages'] as List;
    for (final m in msgs) {
      if (m['role'] == 'system') continue;
      await _writeFrame(
        resp,
        _openAiDelta('${m['role']}:${m['content']}|'),
        s.clientDisconnected,
      );
    }
    await _writeFrame(resp, '[DONE]', s.clientDisconnected);
    await resp.close();
  }

  // ── 测试 A：正常 delta 流，按序产出并正常结束 ──
  test('A. 正常 delta 流按序产出并正常结束', () async {
    final s = await _startMock((resp, s, body) async {
      await _writeFrame(resp, _openAiDelta('你'), s.clientDisconnected);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await _writeFrame(resp, _openAiDelta('好'), s.clientDisconnected);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await _writeFrame(resp, '[DONE]', s.clientDisconnected);
      await resp.close();
    });
    final client = _client(s.baseUrl);

    final received = <String>[];
    await for (final d in client.generateResponse([
      ChatMessage(role: MessageRole.user, content: '你好', round: 1),
    ])) {
      received.add(d);
    }
    client.dispose();
    await s.close();

    expect(received, ['你', '好']);
  });

  // ── 测试 B：stop() 提前终止消费 + 服务端感知 socket 提前断开 ──
  test('B. stop() 提前终止且服务端感知连接断开', () async {
    final s = await _startMock((resp, s2, body) async {
      try {
        for (var i = 0; i < 100; i++) {
          if (s2.clientDisconnected.isCompleted) return;
          await _writeFrame(resp, _openAiDelta('帧$i'), s2.clientDisconnected);
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      } catch (_) {
        // 客户端断开后写失败：取消传播已生效。
      }
      await resp.close().catchError((_) {});
    });
    final client = _client(s.baseUrl);

    final received = <String>[];
    await for (final d in client.generateResponse([
      ChatMessage(role: MessageRole.user, content: '慢一点', round: 1),
    ])) {
      received.add(d);
      if (received.length == 1) client.stop(); // 收到首帧后立刻中止
    }
    client.dispose();

    // 断言：仅收到首帧。bufferOutput=false 保证帧每 50ms 增量到达，因此这是
    // 真断言——若 stop() 失效，客户端会继续收到 帧1..帧N（直至 [DONE] 或发满）。
    // 直连下客户端断开即断开厂商 socket，无服务端中继环节。
    expect(received, ['帧0']);
    await s.close();
  });

  // ── 测试 C：帧间空闲超时被上报为 TimeoutException ──
  //
  // 首帧后服务端保持流打开、不再下发任何字节；超过帧超时（200ms）后客户端应抛
  // [TimeoutException]（帧间空闲语义，非总时长）。
  test('C. 帧间空闲超时被上报为 TimeoutException', () async {
    final s = await _startMock((resp, s, body) async {
      await _writeFrame(resp, _openAiDelta('一'), s.clientDisconnected);
      // 保持打开、不再发帧：挂起一个永不完成的等待（服务端由 finally 强制关闭）。
      await Completer<void>().future;
    });
    final client = _client(s.baseUrl,
        frameTimeout: const Duration(milliseconds: 200));

    final received = <String>[];
    Object? caught;
    try {
      await for (final d in client.generateResponse([
        ChatMessage(role: MessageRole.user, content: '超时', round: 1),
      ])) {
        received.add(d);
      }
    } on TimeoutException catch (e) {
      caught = e; // 帧间空闲超时 → TimeoutException
    } finally {
      client.dispose();
      await s.close(); // 强制关闭 mock 服务端，释放挂起的连接
    }

    expect(received, ['一']); // 仅收到首帧
    expect(caught, isA<TimeoutException>());
  });

  // ── 测试 D：上下文装配——round==0 欢迎语被过滤，尾部用户消息随请求发送 ──
  test('D. round==0 欢迎语被过滤，尾部用户消息随请求发送', () async {
    final s = await _startMock(echoMessages);
    final client = _client(s.baseUrl);

    final received = <String>[];
    await for (final d in client.generateResponse([
      ChatMessage(role: MessageRole.ai, content: '欢迎语', round: 0),
      ChatMessage(role: MessageRole.ai, content: '旧回答', round: 1),
      ChatMessage(role: MessageRole.user, content: '问题1', round: 1),
      ChatMessage(role: MessageRole.user, content: '问题2', round: 2),
    ])) {
      received.add(d);
    }
    client.dispose();
    await s.close();

    // 请求体：欢迎语被滤，历史映射 user/assistant，尾部用户消息在末尾
    expect(received.join(), 'assistant:旧回答|user:问题1|user:问题2|');
  });

  // ── 测试 E：预算内历史全量携带（不再固定取尾 10 条）──
  test('E. 预算内历史全量携带', () async {
    final s = await _startMock(echoMessages);
    final client = _client(s.baseUrl);

    final history = <ChatMessage>[];
    for (var r = 1; r <= 15; r++) {
      history.add(ChatMessage(
        role: r.isOdd ? MessageRole.user : MessageRole.ai,
        content: '消息$r',
        round: r,
      ));
    }
    history.add(
        ChatMessage(role: MessageRole.user, content: '新问题', round: 16));

    final received = <String>[];
    await for (final d in client.generateResponse(history)) {
      received.add(d);
    }
    client.dispose();
    await s.close();

    // 默认预算（AppConstants.cloudInputBudget）远大于本对话 → 15 条历史 +
    // 新问题全量携带（旧实现固定取尾 10 条，恒为 11 条）
    expect(received.length, 16);
    expect(received.first, 'user:消息1|'); // 消息1 为奇数轮 → 用户角色
    expect(received.last, 'user:新问题|');
  });

  // ── 测试 K：小预算触发装窗——仅留保底尾部，移出消息进摘要器 ──
  test('K. 小预算时仅保留保底尾部，移出消息进摘要器', () async {
    final s = await _startMock(echoMessages);
    final summarizer = _FakeSummarizer();
    final client = _client(
      s.baseUrl,
      policy: CloudContextPolicy(
        baseUrl: s.baseUrl,
        apiKey: _dummyKey,
        modelName: _dummyModel,
        budget: 0, // 任何历史都超预算 → 只留 minKeep=2
        summarizer: summarizer,
      ),
    );

    final received = <String>[];
    await for (final d in client.generateResponse([
      ChatMessage(role: MessageRole.user, content: 'q1', round: 1),
      ChatMessage(role: MessageRole.ai, content: 'a1', round: 1),
      ChatMessage(role: MessageRole.user, content: 'q2', round: 2),
      ChatMessage(role: MessageRole.ai, content: 'a2', round: 2),
      ChatMessage(role: MessageRole.user, content: 'q3', round: 3),
      ChatMessage(role: MessageRole.ai, content: 'a3', round: 3),
    ])) {
      received.add(d);
    }
    client.dispose();
    await s.close();

    // 预算 0 + minKeep 2 → 装窗只保留最后 2 条；被移出的 4 条进摘要器
    expect(received, ['user:q3|', 'assistant:a3|']);
    expect(summarizer.calls, 1);
    expect(summarizer.lastEvicted.length, 4);
  });

  // ── 测试 F：isReady 恒真；initialize 暂存 goals 且恒成功 ──
  test('F. isReady 恒真，initialize 暂存 goals', () async {
    final client = _client('https://example.com');
    expect(client.isReady, isTrue);

    final ok = await client.initialize(
      existingGoals: [
        Goal(
          title: '学英语',
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
        ),
      ],
    );
    expect(ok, isTrue);
    expect(client.isReady, isTrue);
  });

  // ── 测试 G：请求体为 OpenAI 格式——system 人设（goals）+ model + Bearer 头 ──
  test('G. 请求体含 system 人设/model/Authorization，goals 注入', () async {
    Map<String, dynamic>? capturedBody;
    String? capturedAuth;
    final s = await _startMock((resp, s2, body) async {
      capturedBody = jsonDecode(body) as Map<String, dynamic>;
      capturedAuth = s2.lastRequest?.headers.value('authorization');
      await _writeFrame(resp, _openAiDelta('ok'), s2.clientDisconnected);
      await _writeFrame(resp, '[DONE]', s2.clientDisconnected);
      await resp.close();
    });
    final client = _client(s.baseUrl);
    await client.initialize(
      existingGoals: [
        Goal(
          title: '三个月内找到 iOS 工作',
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
        ),
      ],
    );

    final received = <String>[];
    await for (final d in client.generateResponse([
      ChatMessage(role: MessageRole.user, content: '近况', round: 1),
    ])) {
      received.add(d);
    }
    client.dispose();
    await s.close();

    expect(received, ['ok']);
    expect(capturedBody, isNotNull);
    expect(capturedBody!['model'], _dummyModel);
    expect(capturedBody!['stream'], isTrue);
    expect(capturedAuth, 'Bearer $_dummyKey');

    // system 首条：统一人设（与 ConversationStrategy.buildSystemPrompt 一致）
    // + goals 注入段
    final messages = capturedBody!['messages'] as List;
    expect(messages.first['role'], 'system');
    final system = messages.first['content'] as String;
    expect(system, contains('你是知行AI'));
    expect(system, contains('Markdown'));
    expect(system, contains('## 用户已有目标'));
    expect(system, contains('[active] 三个月内找到 iOS 工作'));
    expect(system, contains('建议合并而非新建'));
  });

  // ── 测试 H：未调 initialize（无 goals）→ system 仍发送，不含目标段 ──
  test('H. 无 goals 时 system 不含目标段', () async {
    Map<String, dynamic>? capturedBody;
    final s = await _startMock((resp, s2, body) async {
      capturedBody = jsonDecode(body) as Map<String, dynamic>;
      await _writeFrame(resp, _openAiDelta('ok'), s2.clientDisconnected);
      await _writeFrame(resp, '[DONE]', s2.clientDisconnected);
      await resp.close();
    });
    final client = _client(s.baseUrl);

    await for (final _ in client.generateResponse([
      ChatMessage(role: MessageRole.user, content: '近况', round: 1),
    ])) {}
    client.dispose();
    await s.close();

    final messages = capturedBody!['messages'] as List;
    final system = messages.first['content'] as String;
    expect(system, contains('你是知行AI'));
    expect(system, isNot(contains('## 用户已有目标')));
  });

  // ── 测试 I：HTTP 非 200 → 抛错且错误信息含状态码 ──
  test('I. 上游 401 → 抛错含 HTTP 状态码', () async {
    final s = await _startMock((resp, s2, body) async {
      resp.statusCode = 401;
      resp.write('{"error":{"message":"Invalid API key"}}');
      await resp.close();
    });
    final client = _client(s.baseUrl);

    Object? caught;
    try {
      await for (final _ in client.generateResponse([
        ChatMessage(role: MessageRole.user, content: '近况', round: 1),
      ])) {}
    } catch (e) {
      caught = e;
    } finally {
      client.dispose();
      await s.close();
    }

    expect(caught, isNotNull);
    expect(caught.toString(), contains('401'));
  });

  // ── 测试 J：无 delta.content 的帧（role/finish_reason）被跳过 ──
  test('J. 无 content 的帧被跳过，不产出空 delta', () async {
    final s = await _startMock((resp, s, body) async {
      // role 帧（OpenAI 首帧常见）
      await _writeFrame(
          resp, '{"choices":[{"delta":{"role":"assistant"}}]}',
          s.clientDisconnected);
      // finish_reason 帧
      await _writeFrame(
          resp,
          '{"choices":[{"delta":{},"finish_reason":"stop"}]}',
          s.clientDisconnected);
      // 正常内容帧夹在中间
      await _writeFrame(resp, _openAiDelta('好'), s.clientDisconnected);
      await _writeFrame(resp, '[DONE]', s.clientDisconnected);
      await resp.close();
    });
    final client = _client(s.baseUrl);

    final received = <String>[];
    await for (final d in client.generateResponse([
      ChatMessage(role: MessageRole.user, content: '近况', round: 1),
    ])) {
      received.add(d);
    }
    client.dispose();
    await s.close();

    expect(received, ['好']);
  });
}
