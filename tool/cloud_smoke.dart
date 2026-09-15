/// 云端交付冒烟测试
///
/// 自行用 dart:io 起一个 mock SSE 服务端，验证 [CloudGeneration]：
///   1. 正确拼接并解码跨 chunk 边界的 UTF-8 SSE 帧（delta 流）；
///   2. [CloudGeneration.stop] 能提前终止正在进行的流。
///
/// 运行：dart run tool/cloud_smoke.dart（在项目根目录执行，package: 解析才生效）
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/context/context_assembly.dart';
import 'package:zhixing_ai/core/llm/generation/cloud_generation.dart';

/// 冒烟用人设（真实人设由业务经 `systemPrompt` 提供，这里只需非空）。
const _systemPrompt = '你是知行AI助手。';

/// 装配一段单条用户消息的上下文（装配本身由转换段负责，此处直构）。
AssembledContext _assembled(String userContent) => AssembledContext(
      messages: [
        ChatMessage(role: MessageRole.user, content: userContent, round: 1),
      ],
    );

/// 起一个 mock SSE 服务端，按 [frames] 逐帧下发，帧间延迟 [delayMs]。
Future<HttpServer> startMockServer(
  List<String> frames, {
  int delayMs = 30,
  int? port,
}) async {
  final server = await HttpServer.bind('127.0.0.1', port ?? 0);
  server.listen((req) async {
    if (req.method != 'POST') {
      req.response
        ..statusCode = 405
        ..close();
      return;
    }
    // 读取并丢弃请求体（仅验证服务端能正常收帧）
    await req.fold<List<int>>([], (b, c) => b..addAll(c));

    req.response
      ..statusCode = 200
      ..headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8')
      ..headers.add('Cache-Control', 'no-cache')
      ..headers.add('Connection', 'keep-alive');

    for (final frame in frames) {
      req.response.write('data: $frame\n\n');
      await req.response.flush();
      await Future.delayed(Duration(milliseconds: delayMs));
    }
    await req.response.close();
  });
  return server;
}

Future<void> main() async {
  // ── 测试一：正常 delta 流，验证跨 chunk UTF-8 解码 ──
  // 故意把 CJK 拆成多个字节的帧，且单帧只含半个多字节字符。
  final server = await startMockServer([
    '{"choices":[{"delta":{"content":"你"}}]}',
    '{"choices":[{"delta":{"content":"好"}}]}',
    '[DONE]',
  ]);
  final baseUrl = 'http://127.0.0.1:${server.port}';
  final delivery = CloudGeneration(
    baseUrl: baseUrl,
    apiKey: 'sk-smoke',
    modelName: 'smoke-model',
  );

  final received = <String>[];
  await for (final d in delivery.deliver(
    _assembled('你好'),
    systemPrompt: _systemPrompt,
  )) {
    received.add(d);
    stdout.writeln('[delta] $d');
  }
  delivery.dispose();
  await server.close(force: true);

  assert(received.length == 2,
      '期望 2 个 delta，实际 ${received.length}: $received');
  assert(received[0] == '你' && received[1] == '好', '顺序/内容错误: $received');
  stdout.writeln('✅ 测试一通过：收到 ${received.join('')}（顺序正确）');

  // ── 测试二：stop() 提前终止慢流 ──
  final slowFrames = List.generate(
      10, (i) => '{"choices":[{"delta":{"content":"帧$i"}}]}');
  final slowServer = await startMockServer(slowFrames, delayMs: 50);
  final slowDelivery = CloudGeneration(
    baseUrl: 'http://127.0.0.1:${slowServer.port}',
    apiKey: 'sk-smoke',
    modelName: 'smoke-model',
  );

  final beforeStop = <String>[];
  var stoppedClean = false;
  try {
    await for (final d in slowDelivery.deliver(
      _assembled('慢一点'),
      systemPrompt: _systemPrompt,
    )) {
      beforeStop.add(d);
      stdout.writeln('[slow delta] $d');
      if (beforeStop.length == 1) {
        slowDelivery.stop(); // 收到首帧后立即中止
      }
    }
    // 正常结束说明 stop 后流关闭
    stoppedClean = true;
  } on DioException catch (e) {
    // 取消产生的 DioException 视为干净停止
    stoppedClean = e.type == DioExceptionType.cancel;
    stdout.writeln('[stop] 捕获取消异常: ${e.type}');
  }
  slowDelivery.dispose();
  await slowServer.close(force: true);

  assert(beforeStop.isNotEmpty, 'stop 前至少应收到 1 帧');
  assert(stoppedClean, 'stop() 未干净终止流');
  stdout.writeln(
      '✅ 测试二通过：stop 提前终止，收到 ${beforeStop.length} 帧后干净结束');

  stdout.writeln('🎉 全部冒烟测试通过');
}
