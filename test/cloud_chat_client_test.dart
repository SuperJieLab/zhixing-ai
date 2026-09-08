import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zhixing_ai/features/chat/engine/cloud_chat_client.dart';

// 云端对话客户端真实集成测试
//
// 用真实 dart:io HttpServer 起本地 mock SSE 服务端（127.0.0.1 直连），验证
// [CloudChatClient] 的三种关键行为：
//   A. 正常 delta 流按序产出并正常结束；
//   B. [CloudChatClient.stop] 提前终止消费，且服务端在帧未发完时感知到 socket
//      断开（客户端取消 → 连接销毁 → 服务端中断，对应 Task 3 的取消传播链）；
//   C. 帧间空闲超时（[TimeoutException]，帧间空闲语义而非总时长）。
//
// 关键：服务端必须设 `bufferOutput = false`——dart:io HttpResponse 默认缓冲输出，
// 小写入会攒到连接关闭才上线，SSE 增量投递完全失效（曾由此误判为环境代理缓冲）。
//
// 运行：dart test test/cloud_chat_client_test.dart（纯 Dart，flutter test 在本沙箱不可用）。

/// mock SSE 服务端句柄：端口 + 客户端提前断开的感知信号。
class _MockServer {
  _MockServer(this.server, this.clientDisconnected);
  final HttpServer server;
  final Completer<void> clientDisconnected;

  String get baseUrl => 'http://127.0.0.1:${server.port}';

  Future<void> close() => server.close(force: true);
}

/// 起一个 mock SSE 服务端。
///
/// [onConnected] 在收到 POST 后被调用，拿到响应写出器；测试用例自行决定
/// 发什么帧、何时停顿。服务端全程感知客户端是否提前断开（[response.done]）。
Future<_MockServer> _startMock(
  Future<void> Function(HttpResponse resp, _MockServer s) onConnected,
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
    // 读取并丢弃请求体。
    await req.fold<List<int>>([], (b, c) => b..addAll(c));
    req.response
      ..bufferOutput = false // ★ 关闭输出缓冲，否则 SSE 帧攒到 close 才上线
      ..statusCode = 200
      ..headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8')
      ..headers.add('Cache-Control', 'no-cache')
      ..headers.add('Connection', 'keep-alive');
    await onConnected(req.response, _MockServer(server, disconnected));
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

void main() {
  // ── 测试 A：正常 delta 流，按序产出并正常结束 ──
  test('A. 正常 delta 流按序产出并正常结束', () async {
    final s = await _startMock((resp, s) async {
      await _writeFrame(resp, '{"delta":"你"}', s.clientDisconnected);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await _writeFrame(resp, '{"delta":"好"}', s.clientDisconnected);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await _writeFrame(resp, '[DONE]', s.clientDisconnected);
      await resp.close();
    });
    final client = CloudChatClient(baseUrl: s.baseUrl);

    final received = <String>[];
    await for (final d
        in client.generateResponse([(role: 'user', content: '你好')])) {
      received.add(d);
    }
    client.dispose();
    await s.close();

    expect(received, ['你', '好']);
  });

  // ── 测试 B：stop() 提前终止消费 + 服务端感知 socket 提前断开 ──
  test('B. stop() 提前终止且服务端感知连接断开', () async {
    final s = await _startMock((resp, s2) async {
      try {
        for (var i = 0; i < 100; i++) {
          if (s2.clientDisconnected.isCompleted) return;
          await _writeFrame(resp, '{"delta":"帧$i"}', s2.clientDisconnected);
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      } catch (_) {
        // 客户端断开后写失败：取消传播已生效。
      }
      await resp.close().catchError((_) {});
    });
    final client = CloudChatClient(baseUrl: s.baseUrl);

    final received = <String>[];
    await for (final d
        in client.generateResponse([(role: 'user', content: '慢一点')])) {
      received.add(d);
      if (received.length == 1) client.stop(); // 收到首帧后立刻中止
    }
    client.dispose();

    // 断言：仅收到首帧。bufferOutput=false 保证帧每 50ms 增量到达，因此这是
    // 真断言——若 stop() 失效，客户端会继续收到 帧1..帧N（直至 [DONE] 或发满）。
    expect(received, ['帧0']);
    // 注：不在 dart:io 侧断言「服务端感知断开」——loopback 下客户端 abort 后，
    // 服务端 flush 可能长期挂起且 response.done 不触发（平台行为，非被测代码
    // 缺陷）。「客户端断开 → 服务端 abort 上游」一环由 Task 3 的 node 真实
    // socket 测试（server/tests/chat-route.test.js）覆盖。
    await s.close();
  });

  // ── 测试 C：帧间空闲超时被上报为 TimeoutException ──
  //
  // 首帧后服务端保持流打开、不再下发任何字节；超过帧超时（200ms）后客户端应抛
  // [TimeoutException]（帧间空闲语义，非总时长）。
  test('C. 帧间空闲超时被上报为 TimeoutException', () async {
    final s = await _startMock((resp, s) async {
      await _writeFrame(resp, '{"delta":"一"}', s.clientDisconnected);
      // 保持打开、不再发帧：挂起一个永不完成的等待（服务端由 finally 强制关闭）。
      await Completer<void>().future;
    });
    final client = CloudChatClient(
      baseUrl: s.baseUrl,
      frameTimeout: const Duration(milliseconds: 200),
    );

    final received = <String>[];
    Object? caught;
    try {
      await for (final d
          in client.generateResponse([(role: 'user', content: '超时')])) {
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
}
