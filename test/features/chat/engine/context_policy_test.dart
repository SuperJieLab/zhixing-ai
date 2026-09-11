import 'package:flutter_test/flutter_test.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/features/chat/engine/context_policy.dart';

/// ContextPolicy 共享层单测：过滤 / 装窗 / 装配骨架（fake 度量与摘要器）。
///
/// 覆盖：round==0 剔除、尾部优先装窗、minKeep 保底、预算充足全量透传、
/// evicted 前缀切分、强制收缩、摘要游标（不重复摘要）、摘要失败回落。

ChatMessage _msg(String content, {MessageRole role = MessageRole.user, int round = 1}) =>
    ChatMessage(role: role, content: content, round: round);

/// 代价 = 字符数（可预测，便于断言预算边界）。
class _CharEstimator extends ContextEstimator {
  @override
  int estimateMessage(ChatMessage message) => message.content.length;

  @override
  int estimateText(String text) => text.length;
}

class _RecordingSummarizer implements ConversationSummarizer {
  final List<({String previous, List<ChatMessage> evicted})> calls = [];
  String Function(String previous, List<ChatMessage> evicted)? impl;
  Object? throwError;

  @override
  Future<String> summarize(
      String previousSummary, List<ChatMessage> evicted) async {
    calls.add((previous: previousSummary, evicted: evicted));
    if (throwError != null) throw throwError!;
    return impl?.call(previousSummary, evicted) ?? '摘要(${evicted.length})';
  }
}

class _TestPolicy extends BaseContextPolicy {
  _TestPolicy({
    required super.estimator,
    required super.budget,
    super.summarizer,
    super.minKeep,
    super.overflowKeep,
  });
}

String _contents(List<ChatMessage> msgs) =>
    msgs.map((m) => m.content).join(',');

void main() {
  group('filterEligible（① 过滤·双端共享）', () {
    test('剔除第 0 轮欢迎语，保留其余并维持顺序', () {
      final history = [
        _msg('欢迎语', role: MessageRole.ai, round: 0),
        _msg('第一问', round: 1),
        _msg('第一答', role: MessageRole.ai, round: 1),
        _msg('第二问', round: 2),
      ];

      final eligible = filterEligible(history);

      expect(eligible.length, 3);
      expect(_contents(eligible), '第一问,第一答,第二问');
    });

    test('无第 0 轮消息时原样返回', () {
      final history = [_msg('a'), _msg('b')];
      expect(_contents(filterEligible(history)), 'a,b');
    });
  });

  group('packTailWithinBudget（③ 装窗·双端共享）', () {
    final est = _CharEstimator();

    test('预算充足：全量透传、无移出、used 含 baseCost', () {
      final eligible = [_msg('aaaa'), _msg('bb'), _msg('cccccc')];

      final r = packTailWithinBudget(eligible,
          budget: 100, estimator: est, baseCost: 10);

      expect(_contents(r.kept), 'aaaa,bb,cccccc');
      expect(r.evicted, isEmpty);
      expect(r.used, 10 + 4 + 2 + 6);
    });

    test('超预算：尾部优先保留，evicted 恒为 kept 的前缀', () {
      final eligible = [_msg('aaaa'), _msg('bb'), _msg('cccccc')];

      final r = packTailWithinBudget(eligible,
          budget: 10, estimator: est, baseCost: 0);

      // 尾部两条 6+2=8 装入，加上头部 4 会超 10 → 移出
      expect(_contents(r.kept), 'bb,cccccc');
      expect(_contents(r.evicted), 'aaaa');
      expect(r.used, 8);
      expect(r.hasEviction, isTrue);
    });

    test('长消息少留 / 短消息多留（同一预算）', () {
      final long = [_msg('x' * 100), _msg('x' * 100), _msg('x' * 100)];
      final short = [_msg('y' * 10), _msg('y' * 10), _msg('y' * 10)];

      final rLong = packTailWithinBudget(long,
          budget: 250, estimator: est, baseCost: 0, minKeep: 1);
      final rShort = packTailWithinBudget(short,
          budget: 35, estimator: est, baseCost: 0, minKeep: 1);

      expect(rLong.kept.length, 2);
      expect(rShort.kept.length, 3);
    });

    test('minKeep 保底：预算再紧也留最近 N 条', () {
      final eligible = [_msg('aaaa'), _msg('bb'), _msg('cccccc')];

      final r = packTailWithinBudget(eligible,
          budget: 1, estimator: est, baseCost: 0, minKeep: 2);

      expect(_contents(r.kept), 'bb,cccccc');
      expect(_contents(r.evicted), 'aaaa');
    });

    test('baseCost 占用预算（system + 摘要卡挤占窗口）', () {
      final eligible = [_msg('aaaa'), _msg('bb'), _msg('cccccc')];

      final r = packTailWithinBudget(eligible,
          budget: 100, estimator: est, baseCost: 100, minKeep: 1);

      expect(_contents(r.kept), 'cccccc');
      expect(_contents(r.evicted), 'aaaa,bb');
    });
  });

  group('packKeepLast（溢出自愈·强制收缩）', () {
    final est = _CharEstimator();

    test('只留最后 N 条，其余进入 evicted', () {
      final eligible = [_msg('a'), _msg('bb'), _msg('ccc'), _msg('dddd')];

      final r = packKeepLast(eligible, keep: 2, estimator: est, baseCost: 5);

      expect(_contents(r.kept), 'ccc,dddd');
      expect(_contents(r.evicted), 'a,bb');
      expect(r.used, 5 + 3 + 4);
    });

    test('消息数少于 keep 时全量保留', () {
      final r = packKeepLast([_msg('a')], keep: 4, estimator: est);

      expect(_contents(r.kept), 'a');
      expect(r.evicted, isEmpty);
    });
  });

  group('BaseContextPolicy.assemble（装配骨架）', () {
    test('预算充足：全量透传、无摘要卡、不触发摘要器', () async {
      final summarizer = _RecordingSummarizer();
      final policy = _TestPolicy(
        estimator: _CharEstimator(),
        budget: 1000,
        summarizer: summarizer,
      );

      final ctx = await policy.assemble([
        _msg('欢迎', role: MessageRole.ai, round: 0),
        _msg('问题一'),
        _msg('回答一', role: MessageRole.ai),
      ]);

      expect(_contents(ctx.messages), '问题一,回答一');
      expect(ctx.summaryCard, isNull);
      expect(summarizer.calls, isEmpty);
    });

    test('超预算：移出消息压成摘要卡（带前缀）', () async {
      final summarizer = _RecordingSummarizer();
      final policy = _TestPolicy(
        estimator: _CharEstimator(),
        budget: 60,
        summarizer: summarizer,
        minKeep: 1,
      );

      final ctx = await policy.assemble([_msg('a' * 50), _msg('b' * 50)]);

      expect(_contents(ctx.messages), 'b' * 50);
      expect(ctx.summaryCard, '【此前对话摘要】\n摘要(1)');
      expect(summarizer.calls.length, 1);
      expect(summarizer.calls.single.previous, '');
      expect(_contents(summarizer.calls.single.evicted), 'a' * 50);
    });

    test('摘要游标：历史增长后只对「新移出」的消息再摘要', () async {
      final summarizer = _RecordingSummarizer();
      final policy = _TestPolicy(
        estimator: _CharEstimator(),
        budget: 60,
        summarizer: summarizer,
        minKeep: 1,
      );

      // 第一次：移出 m1
      await policy.assemble([_msg('a' * 50), _msg('b' * 50)]);
      // 第二次：历史增长，预算内只住得下 m3，m1+m2 被移出，但 m1 已摘要过
      final ctx = await policy.assemble(
          [_msg('a' * 50), _msg('b' * 50), _msg('c' * 50)]);

      expect(summarizer.calls.length, 2);
      expect(summarizer.calls.last.previous, '摘要(1)');
      expect(_contents(summarizer.calls.last.evicted), 'b' * 50);
      expect(ctx.summaryCard, isNotNull);
      expect(ctx.summaryCard, startsWith(kSummaryCardPrefix));
    });

    test('历史未再增长：不重复触发摘要器，摘要卡持续注入', () async {
      final summarizer = _RecordingSummarizer();
      final policy = _TestPolicy(
        estimator: _CharEstimator(),
        budget: 60,
        summarizer: summarizer,
        minKeep: 1,
      );

      final history = [_msg('a' * 50), _msg('b' * 50)];
      await policy.assemble(history);
      final ctx = await policy.assemble(history);

      expect(summarizer.calls.length, 1);
      expect(ctx.summaryCard, isNotNull);
    });

    test('摘要器抛错：回落为纯丢弃，不向上抛、保留旧卡', () async {
      final summarizer = _RecordingSummarizer()..throwError = Exception('boom');
      final policy = _TestPolicy(
        estimator: _CharEstimator(),
        budget: 60,
        summarizer: summarizer,
        minKeep: 1,
      );

      final ctx = await policy.assemble([_msg('a' * 50), _msg('b' * 50)]);

      expect(_contents(ctx.messages), 'b' * 50); // 窗口仍正常
      expect(ctx.summaryCard, isNull); // 无摘要问世
    });

    test('无摘要器：仍能装窗，移出消息静默丢弃', () async {
      final policy = _TestPolicy(
        estimator: _CharEstimator(),
        budget: 60,
        minKeep: 1,
      );

      final ctx = await policy.assemble([_msg('a' * 50), _msg('b' * 50)]);

      expect(_contents(ctx.messages), 'b' * 50);
      expect(ctx.summaryCard, isNull);
    });

    test('摘要超长被截断到上限', () async {
      final summarizer = _RecordingSummarizer()
        ..impl = (_, _) => 'x' * 500;
      final policy = _TestPolicy(
        estimator: _CharEstimator(),
        budget: 60,
        summarizer: summarizer,
        minKeep: 1,
      );

      final ctx = await policy.assemble([_msg('a' * 50), _msg('b' * 50)]);

      expect(ctx.summaryCard, '【此前对话摘要】\n${'x' * 200}…');
    });

    test('systemPrompt 参与预算核算', () async {
      final policy = _TestPolicy(
        estimator: _CharEstimator(),
        budget: 100,
        minKeep: 1,
      );

      // 人设占 91，只剩 9：尾部 6 装入，头部 4 被挤出
      final ctx = await policy.assemble(
        [_msg('aaaa'), _msg('cccccc')],
        systemPrompt: 'p' * 91,
      );

      expect(_contents(ctx.messages), 'cccccc');
    });

    test('handleOverflow（overflowKeep=2）：下次装配硬收缩且不摘要', () async {
      final summarizer = _RecordingSummarizer();
      final policy = _TestPolicy(
        estimator: _CharEstimator(),
        budget: 1000, // 预算充裕，正常路径不会收缩
        summarizer: summarizer,
        overflowKeep: 2,
      );

      await policy.handleOverflow();
      final ctx = await policy.assemble(
          [_msg('a'), _msg('b'), _msg('c'), _msg('d')]);

      expect(_contents(ctx.messages), 'c,d');
      expect(summarizer.calls, isEmpty);
    });

    test('handleOverflow（overflowKeep=null）：无害，不改变装配结果', () async {
      final policy = _TestPolicy(
        estimator: _CharEstimator(),
        budget: 1000,
      );

      await policy.handleOverflow();
      final ctx = await policy.assemble([_msg('a'), _msg('b')]);

      expect(_contents(ctx.messages), 'a,b');
    });

    test('强制收缩后不回补：窗口已收窄，旧消息不再纳入也不再被摘要', () async {
      final summarizer = _RecordingSummarizer();
      final policy = _TestPolicy(
        estimator: _CharEstimator(),
        budget: 1000,
        summarizer: summarizer,
        overflowKeep: 2,
      );

      await policy.handleOverflow();
      await policy.assemble([_msg('a'), _msg('b'), _msg('c'), _msg('d')]);
      // 再走正常路径：历史虽含全部 4 条，但窗口已硬丢前 2 条
      final ctx =
          await policy.assemble([_msg('a'), _msg('b'), _msg('c'), _msg('d')]);

      expect(summarizer.calls, isEmpty);
      expect(_contents(ctx.messages), 'c,d');
    });

    test('evicted 标记：预算内为 false，发生移出为 true', () async {
      final policy = _TestPolicy(
        estimator: _CharEstimator(),
        budget: 1000,
        minKeep: 1,
      );

      final roomy = await policy.assemble([_msg('a'), _msg('b')]);
      expect(roomy.evicted, isFalse);

      final tight =
          _TestPolicy(estimator: _CharEstimator(), budget: 1, minKeep: 1);
      final squeezed =
          await tight.assemble([_msg('aaaa'), _msg('bb'), _msg('cccccc')]);
      expect(squeezed.evicted, isTrue);
    });

    test('reset：清空摘要与保留窗口，回到初始状态', () async {
      final summarizer = _RecordingSummarizer();
      final policy = _TestPolicy(
        estimator: _CharEstimator(),
        budget: 60,
        summarizer: summarizer,
        minKeep: 1,
      );

      await policy.assemble([_msg('a' * 50), _msg('b' * 50)]);
      expect(policy.summary, isNotEmpty);
      expect(policy.retainedCount, 1);

      policy.reset();

      expect(policy.summary, isEmpty);
      expect(policy.retainedCount, 0);
      final ctx = await policy.assemble([_msg('x'), _msg('y')]);
      expect(_contents(ctx.messages), 'x,y');
      expect(ctx.summaryCard, isNull);
    });
  });
}
