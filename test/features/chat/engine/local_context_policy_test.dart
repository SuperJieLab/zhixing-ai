import 'package:flutter_test/flutter_test.dart';
import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/llm/llama_service.dart';
import 'package:zhixing_ai/features/chat/engine/context_policy.dart';
import 'package:zhixing_ai/features/chat/engine/local_context_policy.dart';

/// 端侧策略装配测试：度量单位（token + 模板开销）、预算/保底/溢出口径。
///
/// 装配编排本身由 `context_policy_test.dart` 覆盖；此处只验证端侧注入的参数。

class _EchoSummarizer implements ConversationSummarizer {
  int calls = 0;
  List<ChatMessage>? lastEvicted;

  @override
  Future<String> summarize(String previousSummary, List<ChatMessage> evicted) async {
    calls++;
    lastEvicted = evicted;
    return '摘要${evicted.length}';
  }
}

ChatMessage _user(String content) =>
    ChatMessage(role: MessageRole.user, content: content, round: 1);

void main() {
  group('LlamaTemplateEstimator', () {
    final estimator = LlamaTemplateEstimator();

    test('estimateText 委托 LlamaService.estimateTokens', () {
      expect(estimator.estimateText('你好'),
          LlamaService.estimateTokens('你好'));
      expect(estimator.estimateText('hello world'),
          LlamaService.estimateTokens('hello world'));
    });

    test('estimateMessage = token 估算 + 每条模板包装开销', () {
      final cost = estimator.estimateText('你好');
      expect(estimator.estimateMessage(_user('你好')),
          cost + LlamaTemplateEstimator.perMessageOverhead);
      expect(LlamaTemplateEstimator.perMessageOverhead, 16);
    });

    test('estimateMessages 默认逐条累加', () {
      final msgs = [_user('你好'), _user('hello world')];
      expect(
        estimator.estimateMessages(msgs),
        estimator.estimateMessage(msgs[0]) + estimator.estimateMessage(msgs[1]),
      );
    });
  });

  group('LocalContextPolicy 参数装配', () {
    test('预算默认 = localInputBudget（nCtx − 生成上限 − 余量）', () {
      final policy = LocalContextPolicy();
      expect(policy.budget, AppConstants.localInputBudget);
      expect(policy.budget,
          AppConstants.localContextSize -
              AppConstants.localMaxTokens -
              AppConstants.localContextMargin);
    });

    test('保底 2 条、溢出自愈硬留最后 4 条', () {
      final policy = LocalContextPolicy();
      expect(policy.minKeep, 2);
      expect(policy.overflowKeep, 4);
    });

    test('预算可覆盖（测试注入小值强制触发压缩）', () {
      expect(LocalContextPolicy(budget: 7).budget, 7);
    });

    test('超预算时移出消息交给注入的摘要器（能力对等，端侧用端侧模型）', () async {
      final summarizer = _EchoSummarizer();
      // 预算极小 → 除保底 2 条外全部移出
      final policy = LocalContextPolicy(budget: 1, summarizer: summarizer);

      final ctx = await policy.assemble([
        _user('第一问很长很长的问题'),
        _user('第二问也不短的内容'),
        _user('第三问'),
        _user('第四问'),
      ]);

      expect(ctx.evicted, isTrue);
      expect(ctx.messages.length, 2); // 保底 2 条
      expect(summarizer.calls, 1);
      expect(summarizer.lastEvicted!.length, 2);
      expect(ctx.summaryCard, startsWith(kSummaryCardPrefix));
    });

    test('无摘要器（sessionFactory-only）：移出即丢弃，不产出摘要卡', () async {
      final policy = LocalContextPolicy(budget: 1);

      final ctx = await policy.assemble([
        _user('第一问很长很长的问题'),
        _user('第二问也不短的内容'),
        _user('第三问'),
      ]);

      expect(ctx.evicted, isTrue);
      expect(ctx.summaryCard, isNull);
    });
  });
}
