import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/features/chat/engine/cloud_summarizer.dart';

// 云端摘要器真实集成测试：起本地 dart:io HttpServer 当 OpenAI 兼容端点，
// 验证 [CloudSummarizer] 的请求体（非流式 / model / max_tokens / Bearer）、
// 响应解析（choices[0].message.content）、think 剥离与非 2xx 抛错。

const _dummyKey = 'sk-test';
const _dummyModel = 'test-model';

/// mock 端点句柄：记录最近一次请求体与 Authorization 头。
class _Mock {
  _Mock(this.server);
  final HttpServer server;
  Map<String, dynamic>? body;
  String? auth;

  String get baseUrl => 'http://127.0.0.1:${server.port}';
  Future<void> close() => server.close(force: true);
}

/// 起一个固定应答的 mock 端点。
Future<_Mock> _startMock({
  required String responseJson,
  int statusCode = 200,
}) async {
  final server = await HttpServer.bind('127.0.0.1', 0);
  final mock = _Mock(server);
  server.listen((req) async {
    if (req.method != 'POST') {
      req.response
        ..statusCode = 405
        ..close();
      return;
    }
    mock.auth = req.headers.value('authorization');
    final bytes = await req.fold<List<int>>([], (b, c) => b..addAll(c));
    mock.body = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    req.response
      ..bufferOutput = false
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json;
    req.response.write(responseJson);
    await req.response.close();
  });
  return mock;
}

/// OpenAI 非流式应答：`{"choices":[{"message":{"content":...}}]}`。
String _completion(String content) =>
    jsonEncode({
      'choices': [
        {
          'message': {'role': 'assistant', 'content': content},
        },
      ],
    });

CloudSummarizer _summarizer(_Mock m) => CloudSummarizer(
      baseUrl: m.baseUrl,
      apiKey: _dummyKey,
      modelName: _dummyModel,
    );

List<ChatMessage> _evicted() => [
      ChatMessage(role: MessageRole.user, content: '我想找 iOS 工作', round: 1),
      ChatMessage(role: MessageRole.ai, content: '目标已记录', round: 1),
    ];

void main() {
  // ── 请求体：非流式、model、max_tokens、Bearer；提示词复用 buildSummaryPrompt ──
  test('请求体为非流式小请求，提示词复用共享摘要提示词', () async {
    final m = await _startMock(responseJson: _completion('摘要正文'));
    final result = await _summarizer(m).summarize('', _evicted());
    await m.close();

    expect(result, '摘要正文');
    final body = m.body!;
    expect(body['model'], _dummyModel);
    expect(body['stream'], isFalse); // 非流式
    expect(body['max_tokens'], CloudSummarizer.maxTokens);
    expect(m.auth, 'Bearer $_dummyKey');

    final messages = body['messages'] as List;
    expect(messages.length, 2);
    expect(messages[0]['role'], 'system');
    expect(messages[0]['content'], contains('你是对话摘要器'));
    expect(messages[0]['content'], contains('【待压缩对话】'));
    expect(messages[0]['content'], contains('用户: 我想找 iOS 工作'));
    expect(messages[1]['role'], 'user');
    expect(messages[1]['content'], contains('请输出摘要'));
  });

  // ── 递归压实：旧摘要并入提示词 ──
  test('previousSummary 非空时并入提示词（递归压实）', () async {
    final m = await _startMock(responseJson: _completion('合并后的摘要'));
    final result = await _summarizer(m).summarize('旧摘要内容', _evicted());
    await m.close();

    expect(result, '合并后的摘要');
    expect(m.body!['messages'][0]['content'], contains('【此前摘要】'));
    expect(m.body!['messages'][0]['content'], contains('旧摘要内容'));
  });

  // ── think 剥离：思考模型先输出 <think> 块 ──
  test('响应正文剥离 think 标签', () async {
    final m = await _startMock(
        responseJson: _completion('<think>先思考一下</think>真正的摘要'));
    final result = await _summarizer(m).summarize('', _evicted());
    await m.close();

    expect(result, '真正的摘要');
  });

  // ── 非 2xx：抛错且含状态码（由策略兜底回落）──
  test('HTTP 401 → 抛错含状态码', () async {
    final m = await _startMock(
      responseJson: '{"error":{"message":"Invalid API key"}}',
      statusCode: 401,
    );
    Object? caught;
    try {
      await _summarizer(m).summarize('', _evicted());
    } catch (e) {
      caught = e;
    } finally {
      await m.close();
    }

    expect(caught, isNotNull);
    expect(caught.toString(), contains('401'));
  });

  // ── 畸形响应：缺 choices / 缺 content 都抛错（不静默产出空摘要）──
  test('缺 choices → 抛错', () async {
    final m = await _startMock(responseJson: '{}');
    Object? caught;
    try {
      await _summarizer(m).summarize('', _evicted());
    } catch (e) {
      caught = e;
    } finally {
      await m.close();
    }
    expect(caught, isNotNull);
    expect(caught.toString(), contains('choices'));
  });

  test('缺 content → 抛错', () async {
    final m = await _startMock(
        responseJson: jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant'},
            },
          ],
        }));
    Object? caught;
    try {
      await _summarizer(m).summarize('', _evicted());
    } catch (e) {
      caught = e;
    } finally {
      await m.close();
    }
    expect(caught, isNotNull);
    expect(caught.toString(), contains('content'));
  });
}
