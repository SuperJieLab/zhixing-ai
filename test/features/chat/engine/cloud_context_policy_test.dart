import 'package:test/test.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/features/chat/engine/cloud_context_policy.dart';
import 'package:zhixing_ai/features/chat/engine/context_policy.dart';

// 云端上下文策略单测：验证「薄装配」——度量单位、预算、摘要器、溢出语义，
// 以及复用共享层带来的过滤 / 装窗 / 压缩行为。不触网（摘要器注入 fake）。

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
      baseUrl: 'https://example.com',
      apiKey: 'sk-test',
      modelName: 'test-model',
      budget: budget,
      summarizer: summarizer ?? _FakeSummarizer(),
    );

void main() {
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
    final ctx = await p.assemble(_history(3), systemPrompt: 'x' * 100);
    expect(ctx.messages.length, 3);
    expect(ctx.evicted, isFalse);
    expect(ctx.summaryCard, isNull);
  });

  // ── 共享过滤：round==0 欢迎语不参与装配（与端侧同一实现）──
  test('过滤：round==0 欢迎语被剔除', () async {
    final p = _policy();
    final ctx = await p.assemble([
      _msg('欢迎语', MessageRole.ai, 0),
      _msg('问题', MessageRole.user, 1),
    ]);
    expect(ctx.messages.map((m) => m.content), ['问题']);
  });

  // ── 小预算触发压缩：仅留 minKeep，移出消息进摘要器 ──
  test('预算不足：仅留保底尾部，移出消息进摘要器并产出摘要卡', () async {
    final fake = _FakeSummarizer();
    final p = _policy(budget: 0, summarizer: fake);
    final ctx = await p.assemble(_history(4), systemPrompt: 'x' * 50);

    expect(ctx.messages.length, 2); // minKeep
    expect(ctx.evicted, isTrue);
    expect(ctx.summaryCard, contains('摘要正文'));
    expect(fake.calls, 1);
    expect(fake.lastEvicted.length, 2);
  });

  // ── 溢出：overflowKeep == null → 无收缩（契约对称，云端不适用）──
  test('handleOverflow 无害：云端不收缩', () async {
    final fake = _FakeSummarizer();
    final p = _policy(summarizer: fake);
    await p.assemble(_history(3));
    await p.handleOverflow();
    final ctx = await p.assemble(_history(3));
    expect(ctx.messages.length, 3);
    expect(ctx.evicted, isFalse);
    expect(fake.calls, 0);
  });

  // ── 会话生命周期：reset 清空摘要与保留窗口 ──
  test('reset：清空摘要与保留窗口', () async {
    final p = _policy(budget: 0, summarizer: _FakeSummarizer());
    await p.assemble(_history(4), systemPrompt: 'x' * 50);
    expect(p.summary, isNotEmpty);
    expect(p.retainedCount, 2);

    p.reset();
    expect(p.summary, isEmpty);
    expect(p.retainedCount, 0);
  });
}
