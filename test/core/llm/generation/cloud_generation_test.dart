import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/context/context_assembly.dart';
import 'package:zhixing_ai/core/llm/generation/cloud_generation.dart';

// 云端交付（BYOK 直连）真实集成测试
//
// 用真实 dart:io HttpServer 起本地 mock OpenAI 兼容 SSE 服务端（127.0.0.1
// 直连），验证 [CloudGeneration] 的关键行为：
//   A. 正常 delta 流按序产出并正常结束；
//   B. [CloudGeneration.stop] 提前终止消费，且服务端在帧未发完时感知到 socket
//      断开（客户端取消 → 连接销毁 → 厂商侧中断）；
//   C. 帧间空闲超时（[TimeoutException]，帧间空闲语义而非总时长）；
//   D. 装配结果按序映射为 OpenAI messages（转换段的 round==0 过滤在此复现一次）；
//   E. 多轮历史全量按序映射（不截断——预算内全量携带属转换段职责）；
//   F. isReady 恒真、ensureReady 幂等、prime 为 no-op（云端无会话态）；
//   G. 请求体：system 人设（业务原样透传，含业务注入的目标段）+ model + Bearer 头；
//   H. 摘要卡作为第二条 system 紧随人设；
//   I. HTTP 非 200（401）→ 流上抛错且含状态码；
//   J. 无 delta.content 的帧（role/finish_reason）被跳过。
//
// **装配相关用例**（预算内全量携带、小预算装窗 + 摘要器）已随状态外置迁至
// `test/core/llm/context_assembly_test.dart` 与 `cloud_context_policy_test.dart`，
// 本文件只覆盖「怎么把装配结果送进模型」。
//
// 关键：服务端必须设 `bufferOutput = false`——dart:io HttpResponse 默认缓冲输出，
// 小写入会攒到连接关闭才上线，SSE 增量投递完全失效（曾由此误判为环境代理缓冲）。

const _dummyKey = 'sk-test';
const _dummyModel = 'test-model';
const _systemPrompt = '你是知行AI助手（人设由业务提供）。';

/// 直构装配结果（装配正确性由转换段自测）。
AssembledContext _assembled(List<ChatMessage> messages, {String? summaryCard}) =>
    AssembledContext(messages: messages, summaryCard: summaryCard);

ChatMessage _user(String content, int round) =>
    ChatMessage(role: MessageRole.user, content: content, round: round);

ChatMessage _ai(String content, int round) =>
    ChatMessage(role: MessageRole.ai, content: content, round: round);

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

CloudGeneration _delivery(String baseUrl, {Duration? frameTimeout}) =>
    CloudGeneration(
      baseUrl: baseUrl,
      apiKey: _dummyKey,
      modelName: _dummyModel,
      frameTimeout: frameTimeout ?? const Duration(seconds: 10),
    );

/// 收流为列表（交付层的取回段没有本地那层 think 处理，云端不剥 think）。
Future<List<String>> _collect(CloudGeneration d, AssembledContext ctx) =>
    d.deliver(ctx, systemPrompt: _systemPrompt).toList();

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
    final delivery = _delivery(s.baseUrl);

    final received = await _collect(delivery, _assembled([_user('你好', 1)]));
    delivery.dispose();
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
    final delivery = _delivery(s.baseUrl);

    final received = <String>[];
    await for (final d
        in delivery.deliver(_assembled([_user('慢一点', 1)]),
            systemPrompt: _systemPrompt)) {
      received.add(d);
      if (received.length == 1) delivery.stop(); // 收到首帧后立刻中止
    }
    delivery.dispose();

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
    final delivery = _delivery(s.baseUrl,
        frameTimeout: const Duration(milliseconds: 200));

    final received = <String>[];
    Object? caught;
    try {
      await for (final d
          in delivery.deliver(_assembled([_user('超时', 1)]),
              systemPrompt: _systemPrompt)) {
        received.add(d);
      }
    } on TimeoutException catch (e) {
      caught = e; // 帧间空闲超时 → TimeoutException
    } finally {
      delivery.dispose();
      await s.close(); // 强制关闭 mock 服务端，释放挂起的连接
    }

    expect(received, ['一']); // 仅收到首帧
    expect(caught, isA<TimeoutException>());
  });

  // ── 测试 D：装配结果按序映射（round==0 过滤归转换段） ──
  test('D. 装配结果按序映射为 messages；round==0 已由转换段过滤', () async {
    final s = await _startMock(echoMessages);
    final delivery = _delivery(s.baseUrl);

    // 复现转换段的过滤：欢迎语（round==0）不进上下文。
    final history = [
      _ai('欢迎语', 0),
      _ai('旧回答', 1),
      _user('问题1', 1),
      _user('问题2', 2),
    ];
    final assembled = _assembled(filterEligible(history));

    final received = await _collect(delivery, assembled);
    delivery.dispose();
    await s.close();

    // 请求体：欢迎语被滤，历史映射 user/assistant，尾部用户消息在末尾
    expect(received.join(), 'assistant:旧回答|user:问题1|user:问题2|');
  });

  // ── 测试 E：装配结果全量按序映射（不截断）──
  test('E. 装配结果全量按序映射，不截断', () async {
    final s = await _startMock(echoMessages);
    final delivery = _delivery(s.baseUrl);

    final history = <ChatMessage>[];
    for (var r = 1; r <= 15; r++) {
      history.add(ChatMessage(
        role: r.isOdd ? MessageRole.user : MessageRole.ai,
        content: '消息$r',
        round: r,
      ));
    }
    history.add(_user('新问题', 16));

    final received = await _collect(delivery, _assembled(history));
    delivery.dispose();
    await s.close();

    // 派生的装配窗口有多少条，就发多少条（预算判断在转换段）
    expect(received.length, 16);
    expect(received.first, 'user:消息1|'); // 消息1 为奇数轮 → 用户角色
    expect(received.last, 'user:新问题|');
  });

  // ── 测试 F：isReady 恒真；ensureReady 幂等且无副作用 ──
  test('F. isReady 恒真，ensureReady 幂等', () async {
    final delivery = _delivery('https://example.com');
    expect(delivery.isReady, isTrue);

    await delivery.ensureReady();
    await delivery.ensureReady();
    expect(delivery.isReady, isTrue);
  });

  // ── 测试 G：请求体为 OpenAI 格式——system 人设 + model + Bearer 头 ──
  test('G. 请求体含 system 人设/model/Authorization，人设原样透传', () async {
    Map<String, dynamic>? capturedBody;
    String? capturedAuth;
    final s = await _startMock((resp, s2, body) async {
      capturedBody = jsonDecode(body) as Map<String, dynamic>;
      capturedAuth = s2.lastRequest?.headers.value('authorization');
      await _writeFrame(resp, _openAiDelta('ok'), s2.clientDisconnected);
      await _writeFrame(resp, '[DONE]', s2.clientDisconnected);
      await resp.close();
    });
    final delivery = _delivery(s.baseUrl);

    // 业务人设（含目标注入段）——交付层只做透传，不重组人设
    const goalsPrompt = '$_systemPrompt\n\n## 用户已有目标\n'
        '[active] 三个月内找到 iOS 工作\n建议合并而非新建';

    final received = await delivery
        .deliver(_assembled([_user('近况', 1)]), systemPrompt: goalsPrompt)
        .toList();
    delivery.dispose();
    await s.close();

    expect(received, ['ok']);
    expect(capturedBody, isNotNull);
    expect(capturedBody!['model'], _dummyModel);
    expect(capturedBody!['stream'], isTrue);
    expect(capturedAuth, 'Bearer $_dummyKey');

    // system 首条 = 业务传入的人设（逐字），无交付层重组
    final messages = capturedBody!['messages'] as List;
    expect(messages.first['role'], 'system');
    expect(messages.first['content'], goalsPrompt);
  });

  // ── 测试 H：摘要卡作为第二条 system 紧随人设 ──
  test('H. 摘要卡作为第二条 system，排在历史之前', () async {
    Map<String, dynamic>? capturedBody;
    final s = await _startMock((resp, s2, body) async {
      capturedBody = jsonDecode(body) as Map<String, dynamic>;
      await _writeFrame(resp, _openAiDelta('ok'), s2.clientDisconnected);
      await _writeFrame(resp, '[DONE]', s2.clientDisconnected);
      await resp.close();
    });
    final delivery = _delivery(s.baseUrl);

    await _collect(
      delivery,
      _assembled([_user('近况', 1)],
          summaryCard: '$kSummaryCardPrefix\n此前聊过换工作'),
    );
    delivery.dispose();
    await s.close();

    final messages = capturedBody!['messages'] as List;
    expect(messages[0], {'role': 'system', 'content': _systemPrompt});
    expect(messages[1], {
      'role': 'system',
      'content': '$kSummaryCardPrefix\n此前聊过换工作',
    });
    expect(messages[2]['role'], 'user');
  });

  // ── 测试 I：HTTP 非 200 → 流上抛错且错误信息含状态码 ──
  test('I. 上游 401 → 抛错含 HTTP 状态码', () async {
    final s = await _startMock((resp, s2, body) async {
      resp.statusCode = 401;
      resp.write('{"error":{"message":"Invalid API key"}}');
      await resp.close();
    });
    final delivery = _delivery(s.baseUrl);

    Object? caught;
    try {
      await _collect(delivery, _assembled([_user('近况', 1)]));
    } catch (e) {
      caught = e;
    } finally {
      delivery.dispose();
      await s.close();
    }

    expect(caught, isNotNull);
    expect(caught.toString(), contains('401'));
  });

  // ── 测试 J：无 delta.content 的帧（role/finish_reason）被跳过 ──
  test('J. 无 content 的帧被跳过，不产出空 delta', () async {
    final s = await _startMock((resp, s, body) async {
      // role 帧（OpenAI 首帧常见）
      await _writeFrame(resp, '{"choices":[{"delta":{"role":"assistant"}}]}',
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
    final delivery = _delivery(s.baseUrl);

    final received = await _collect(delivery, _assembled([_user('近况', 1)]));
    delivery.dispose();
    await s.close();

    expect(received, ['好']);
  });

  // ── 附加：prime 为 no-op（云端无会话态，契约对称） ──
  test('K. prime 为 no-op：云端无会话态可预置', () {
    final delivery = _delivery('https://example.com');
    // 不应抛异常，也不产生任何可观察行为
    delivery.prime(_assembled([_user('q', 1)]), systemPrompt: _systemPrompt);
    expect(delivery.isReady, isTrue);
  });
}
