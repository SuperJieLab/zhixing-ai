import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/llm/single_shot/cloud_request.dart';
import 'package:zhixing_ai/core/context/cloud_context_policy.dart';
import 'package:zhixing_ai/core/context/context_assembly.dart';
import 'package:zhixing_ai/core/model_gateway.dart';

// 云端后端策略单元测试：与 lib 侧 cloud_context_policy.dart 镜像对应。覆盖三部分：
//
//   Ⅰ 度量与装配：验证「薄装配」——度量单位、预算、摘要器、溢出语义，以及
//     复用共享层带来的过滤 / 装窗 / 压缩行为。不触网（摘要器注入 fake）。
//   Ⅱ CloudCompletionRequest（传输层直测）：起本地 dart:io HttpServer 当 OpenAI 兼容
//     端点，验证请求体（非流式 / model / max_tokens / Bearer）、响应解析
//     （choices[0].message.content）与非 2xx / 畸形响应抛错。
//     （摘要的 think 剥离已随通道收敛进服务 `_defaultCloudAsk`，不在本层。）
//   Ⅲ AskSummarizer（门面内聚的摘要适配）：提示词与输出上限（fake 通道，不触网）。
//
// Ⅱ 的 mock 端点与 cloud_chat_client_test 同一约定：服务端必须设
// `bufferOutput = false`，否则小写入会攒到连接关闭才上线。

// ───────────── Ⅰ 度量与装配：helper ─────────────

class _FakeSummarizer implements ConversationSummarizer {
  int calls = 0;
  List<ChatMessage> lastEvicted = const [];

  @override
  Future<String> summarize(
      String previousSummary, List<ChatMessage> evicted) async {
    calls++;
    lastEvicted = evicted;
    return '摘要正文';
  }
}

ChatMessage _msg(String content, MessageRole role, int round) =>
    ChatMessage(role: role, content: content, round: round);

List<ChatMessage> _history(int n) => [
      for (var i = 1; i <= n; i++)
        _msg('消息$i', i.isOdd ? MessageRole.user : MessageRole.ai, i),
    ];

CloudContextPolicy _policy({
  int? budget,
  ConversationSummarizer? summarizer,
}) =>
    CloudContextPolicy(
      budget: budget,
      summarizer: summarizer ?? _FakeSummarizer(),
    );

// ───────────── Ⅱ CloudCompletionRequest 传输层：mock 端点 ─────────────

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

CloudCompletionRequest _client(_Mock m) => CloudCompletionRequest(
      baseUrl: m.baseUrl,
      apiKey: _dummyKey,
      modelName: _dummyModel,
    );

List<ChatMessage> _evicted() => [
      ChatMessage(role: MessageRole.user, content: '我想找 iOS 工作', round: 1),
      ChatMessage(role: MessageRole.ai, content: '目标已记录', round: 1),
    ];

void main() {
  // ═══════════ Ⅰ 度量与装配（不触网） ═══════════

  // ── 度量（策略位②）：字符数近似 + 每条包装开销 ──
  test('CharCountEstimator：估文本 = 字符数，消息额外计包装开销', () {
    final est = CharCountEstimator();
    expect(est.estimateText('abc'), 3);
    expect(est.estimateMessage(_msg('abcd', MessageRole.user, 1)),
        4 + CharCountEstimator.perMessageOverhead);
    // 默认逐条累加
    expect(
      est.estimateMessages(_history(3)),
      _history(3).fold(
          0, (s, m) => s + m.content.length + CharCountEstimator.perMessageOverhead),
    );
  });

  // ── 预算内透传：全量携带、不压缩 ──
  test('预算内：历史全量携带，不触发压缩', () async {
    final p = _policy();
    final ctx = await p.assemble(_history(3),
        state: ContextState(), systemPrompt: 'x' * 100);
    expect(ctx.messages.length, 3);
    expect(ctx.summaryCard, isNull);
  });

  // ── 共享过滤：round==0 欢迎语不参与装配（与端侧同一实现）──
  test('过滤：round==0 欢迎语被剔除', () async {
    final p = _policy();
    final ctx = await p.assemble([
      _msg('欢迎语', MessageRole.ai, 0),
      _msg('问题', MessageRole.user, 1),
    ], state: ContextState());
    expect(ctx.messages.map((m) => m.content), ['问题']);
  });

  // ── 小预算触发压缩：仅留 minKeep，移出消息进摘要器 ──
  test('预算不足：仅留保底尾部，移出消息进摘要器并产出摘要卡', () async {
    final fake = _FakeSummarizer();
    final p = _policy(budget: 0, summarizer: fake);
    final ctx = await p.assemble(_history(4),
        state: ContextState(), systemPrompt: 'x' * 50);

    expect(ctx.messages.length, 2); // minKeep
    expect(ctx.summaryCard, contains('摘要正文'));
    expect(fake.calls, 1);
    expect(fake.lastEvicted.length, 2);
  });

  // ── 溢出：overflowKeep == null → 无收缩（契约对称，云端不适用）──
  test('handleOverflow 无害：云端不收缩', () async {
    final fake = _FakeSummarizer();
    final p = _policy(summarizer: fake);
    final state = ContextState();
    await p.assemble(_history(3), state: state);
    p.handleOverflow(state);
    final ctx = await p.assemble(_history(3), state: state);
    expect(ctx.messages.length, 3);
    expect(fake.calls, 0);
  });

  // ── 会话生命周期：reset 清空摘要与覆盖游标 ──
  test('reset：清空摘要与覆盖游标', () async {
    final p = _policy(budget: 0, summarizer: _FakeSummarizer());
    final state = ContextState();
    final ctx = await p.assemble(_history(4),
        state: state, systemPrompt: 'x' * 50);
    expect(state.summary, isNotEmpty);
    expect(ctx.messages.length, 2);

    state.reset();
    expect(state.summary, isEmpty);
    expect(state.k, 0);
  });

  // ═══════════ Ⅱ CloudCompletionRequest（本地 mock 端点） ═══════════

  // ── 请求体：非流式、model、max_tokens、Bearer ──
  test('请求体为非流式补全请求，带 model 与 Bearer', () async {
    final m = await _startMock(responseJson: _completion('任意正文'));
    final result = await _client(m).complete(
          system: 'sys',
          user: 'usr',
          maxTokens: AskSummarizer.maxTokens,
        );
    await m.close();

    expect(result, '任意正文');
    final body = m.body!;
    expect(body['model'], _dummyModel);
    expect(body['stream'], isFalse); // 非流式
    expect(body['max_tokens'], AskSummarizer.maxTokens);
    expect(m.auth, 'Bearer $_dummyKey');
  });

  // ── 非 2xx：抛错且含状态码（由策略兜底回落）──
  test('HTTP 401 → 抛错含状态码', () async {
    final m = await _startMock(
      responseJson: '{"error":{"message":"Invalid API key"}}',
      statusCode: 401,
    );
    Object? caught;
    try {
      await _client(m).complete(system: 's', user: 'u');
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
      await _client(m).complete(system: 's', user: 'u');
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
      await _client(m).complete(system: 's', user: 'u');
    } catch (e) {
      caught = e;
    } finally {
      await m.close();
    }
    expect(caught, isNotNull);
    expect(caught.toString(), contains('content'));
  });

  // ═══════════ Ⅲ AskSummarizer（fake 通道，不触网） ═══════════

  // ── 提示词复用 buildSummaryPrompt，输出上限与触发语固定 ──
  test('summarize：system 为共享摘要提示词，user 与 maxTokens 固定', () async {
    final ask = _CapturingAsk();
    final result =
        await AskSummarizer(ask.call).summarize('', _evicted());

    expect(result, '通道返回'); // 原样透传，不做二次加工
    expect(ask.system, contains('你是对话摘要器'));
    expect(ask.system, contains('【待压缩对话】'));
    expect(ask.system, contains('用户: 我想找 iOS 工作'));
    expect(ask.system, contains('助手: 目标已记录'));
    expect(ask.user, '请输出摘要。');
    expect(ask.maxTokens, AskSummarizer.maxTokens);
  });

  // ── 递归压实：旧摘要并入提示词 ──
  test('previousSummary 非空时并入提示词（递归压实）', () async {
    final ask = _CapturingAsk();
    await AskSummarizer(ask.call).summarize('旧摘要内容', _evicted());

    expect(ask.system, contains('【此前摘要】'));
    expect(ask.system, contains('旧摘要内容'));
  });

  // ── 通道异常原样上抛（由 BaseContextPolicy 兜底回落）──
  test('通道抛错 → 原样上抛', () async {
    final ask = _CapturingAsk()..reply = Exception('boom');
    await expectLater(
      AskSummarizer(ask.call).summarize('', _evicted()),
      throwsA(isException),
    );
  });
}

/// 记录调用参数的 fake 单次补全通道（[SingleShotAsk] 形态）。
class _CapturingAsk {
  String? system;
  String? user;
  int? maxTokens;
  Object? reply = '通道返回';

  Future<String> call({
    required String system,
    required String user,
    int? maxTokens,
  }) {
    this.system = system;
    this.user = user;
    this.maxTokens = maxTokens;
    final r = reply;
    if (r is Exception) return Future.error(r);
    return Future.value(r as String);
  }
}
