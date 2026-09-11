import 'package:flutter_test/flutter_test.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/data/models/dashboard_models.dart';
import 'package:zhixing_ai/features/chat/engine/context/context_policy.dart';
import 'package:zhixing_ai/features/chat/engine/client/local_chat_client.dart';
import 'package:zhixing_ai/features/chat/engine/context/local_context_policy.dart';

/// LocalChatClient 单元测试（fake KV 会话注入，不触碰真实 llama）
///
/// 覆盖：增量 diff append（合格消息不含第 0 轮欢迎语）、消费条数推进、
/// 去重改写仅 KV 会话侧、窗口收缩后整体重建 KV 会话、
/// think 标签剥离、取消/失败时不登记 assistant 且下一轮 diff 跳过、
/// context-full 自愈。
///
/// 上下文装配（过滤/装窗/压缩）本身由 ContextPolicy 承担，
/// 其单测见 `context_policy_test.dart` / `local_context_policy_test.dart`。

class _FakeKvSession implements KvSession {
  final List<String> ops = [];
  List<String> tokens = const [];
  Object? throwOnGenerate;

  /// true 时每个 token 后让出一个事件循环（供取消测试在流中途稳定取消）。
  bool pauseBetweenTokens = false;

  @override
  void addSystem(String content) => ops.add('system:$content');

  @override
  void addUser(String content) => ops.add('user:$content');

  @override
  void addAssistant(String content) => ops.add('assistant:$content');

  @override
  Stream<String> generate({int maxTokens = 2048}) async* {
    ops.add('generate:$maxTokens');
    if (throwOnGenerate != null) throw throwOnGenerate!;
    for (final t in tokens) {
      yield t;
      if (pauseBetweenTokens) {
        await Future<void>.delayed(Duration.zero);
      }
    }
  }

  @override
  void dispose() => ops.add('dispose');
}

class _KvSessionFactory {
  final List<_FakeKvSession> created = [];
  Object? throwOnCreate;

  /// 新建 KV 会话预置的生成 tokens（重建发生在 generateResponse 内部，
  /// 无法在调用前拿到新 KV 会话实例逐个设置）。
  List<String> tokensForNew = const [];

  Future<KvSession> call() async {
    if (throwOnCreate != null) throw throwOnCreate!;
    final s = _FakeKvSession()..tokens = tokensForNew;
    created.add(s);
    return s;
  }
}

class _FakeSummarizer implements ConversationSummarizer {
  int callCount = 0;
  String? lastPrevious;
  List<ChatMessage>? lastEvicted;
  Object? throwOnCall;
  String result = '摘要内容';

  @override
  Future<String> summarize(
      String previousSummary, List<ChatMessage> evicted) async {
    callCount++;
    lastPrevious = previousSummary;
    lastEvicted = evicted;
    if (throwOnCall != null) throw throwOnCall!;
    return result;
  }
}

const _welcome = ChatMessage(role: MessageRole.ai, content: '欢迎语', round: 0);

ChatMessage _user(String content, int round) =>
    ChatMessage(role: MessageRole.user, content: content, round: round);

ChatMessage _ai(String content, int round) =>
    ChatMessage(role: MessageRole.ai, content: content, round: round);

/// 预算为 0 的策略：装窗只剩 `minKeep` 条 → 强制走压缩路径。
LocalChatClient _tightClient({
  required _KvSessionFactory factory,
  ConversationSummarizer? summarizer,
}) =>
    LocalChatClient(
      kvSessionFactory: factory.call,
      policy: LocalContextPolicy(budget: 0, summarizer: summarizer),
    );

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('LocalChatClient', () {
    test('未初始化时 generateResponse 返回回退文案', () async {
      final client = LocalChatClient(kvSessionFactory: _KvSessionFactory().call);
      expect(client.isReady, isFalse);

      final out = await client.generateResponse([_welcome]).join();
      expect(out, '助手尚在准备中，请稍后再来。');
    });

    test('initialize 成功 → isReady；goals 注入系统提示词', () async {
      final factory = _KvSessionFactory();
      final client = LocalChatClient(kvSessionFactory: factory.call);

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
      expect(factory.created.single.ops.first, contains('用户已有目标'));
      expect(factory.created.single.ops.first, contains('学英语'));
    });

    test('initialize 失败（工厂抛错）→ 返回 false', () async {
      final factory = _KvSessionFactory()..throwOnCreate = StateError('no model');
      final client = LocalChatClient(kvSessionFactory: factory.call);

      expect(await client.initialize(), isFalse);
      expect(client.isReady, isFalse);
    });

    test('首轮：合格消息入 KV 会话（第 0 轮欢迎语被过滤），生成后登记回复', () async {
      final factory = _KvSessionFactory();
      final client = LocalChatClient(kvSessionFactory: factory.call);
      await client.initialize();

      factory.created.single.tokens = ['回复A'];
      final out =
          await client.generateResponse([_welcome, _user('问题1', 1)]).join();

      expect(out, '回复A');
      expect(
        factory.created.single.ops,
        [
          'system:',
          'user:问题1',
          'generate:2048',
          'assistant:回复A',
        ].map((op) => op == 'system:' ? startsWith('system:') : op),
      );
      // 欢迎语（round==0）不作为对话上下文进入 KV 会话
      expect(factory.created.single.ops.contains('assistant:欢迎语'), isFalse);
    });

    test('二次调用只 append 新增（增量 prefill，不重放已消费消息）', () async {
      final factory = _KvSessionFactory();
      final client = LocalChatClient(kvSessionFactory: factory.call);
      await client.initialize();

      final kv = factory.created.single;
      kv.tokens = ['回复A'];
      await client.generateResponse([_welcome, _user('问题1', 1)]).join();

      kv.tokens = ['回复B'];
      await client
          .generateResponse(
              [_welcome, _user('问题1', 1), _ai('回复A', 1), _user('问题2', 2)])
          .join();

      // 已消费的消息不重复 append
      expect(
        kv.ops.where((op) => op == 'user:问题1').length,
        1,
      );
      // 上一轮回复已在生成时登记：历史里的 回复A 不得再次 append
      expect(
        kv.ops.where((op) => op == 'assistant:回复A').length,
        1,
      );
      // 新增的用户消息 + 生成完成后的 assistant 登记
      expect(kv.ops.contains('user:问题2'), isTrue);
      expect(kv.ops.contains('assistant:回复B'), isTrue);
    });

    test('去重：相邻相同问题在 KV 会话侧改写（mirror 不受影响）', () async {
      final factory = _KvSessionFactory();
      final client = LocalChatClient(kvSessionFactory: factory.call);
      await client.initialize();

      final kv = factory.created.single;
      kv.tokens = ['回复A'];
      await client.generateResponse([_welcome, _user('目标A', 1)]).join();

      kv.tokens = ['回复B'];
      await client
          .generateResponse(
              [_welcome, _user('目标A', 1), _ai('回复A', 1), _user('目标A', 2)])
          .join();

      expect(
        kv.ops.contains('user:目标A（请从不同的角度回答，不要重复之前的观点）'),
        isTrue,
      );
      expect(kv.ops.contains('user:目标A'), isTrue); // 首次调用
    });

    test('压缩：超预算时装窗重建，移出消息进摘要卡', () async {
      final factory = _KvSessionFactory();
      final summarizer = _FakeSummarizer();
      final client = _tightClient(factory: factory, summarizer: summarizer);
      await client.initialize();

      final history = <ChatMessage>[_welcome];
      for (var r = 1; r <= 10; r++) {
        history.add(_user('问题$r', r));
        if (r < 10) history.add(_ai('回复$r', r)); // 尾部保持用户消息
      }
      // 19 条合格历史（欢迎语被过滤）：9 对完整问答 + 尾部问题10

      factory.tokensForNew = ['新回复']; // 重建后的新 KV 会话用
      await client.generateResponse(history).join();

      expect(factory.created.length, 2); // 重建了一次 KV 会话
      expect(factory.created.first.ops.last, 'dispose');

      // 摘要器被调一次：旧摘要为空，evicted = 除保底 2 条外的全部
      expect(summarizer.callCount, 1);
      expect(summarizer.lastPrevious, isEmpty);
      expect(summarizer.lastEvicted!.length, 17);
      expect(
        summarizer.lastEvicted!.first.content,
        '问题1',
      );
      expect(summarizer.lastEvicted!.first.role, MessageRole.user);

      final rebuilt = factory.created.last;
      // 两条 system：人设 + 摘要卡
      expect(rebuilt.ops.where((op) => op.startsWith('system:')).length, 2);
      expect(
        rebuilt.ops.where((op) => op.startsWith('system:')).last,
        'system:【此前对话摘要】\n摘要内容',
      );
      // 预算装窗（预算 0 → 仅保底最后 2 条）+ 生成登记
      expect(
        rebuilt.ops
            .where((op) => op.startsWith('user:') || op.startsWith('assistant:'))
            .toList(),
        [
          'assistant:回复9',
          'user:问题10',
          'assistant:新回复',
        ],
      );
      expect(rebuilt.ops.contains('generate:2048'), isTrue);
      expect(rebuilt.ops.last, 'assistant:新回复');
    });

    test('压缩递归压实：第二次压缩把旧摘要并入 summarizer 入参', () async {
      final factory = _KvSessionFactory();
      final summarizer = _FakeSummarizer();
      final client = _tightClient(factory: factory, summarizer: summarizer);
      await client.initialize();

      final history = <ChatMessage>[_welcome];
      for (var r = 1; r <= 10; r++) {
        history.add(_user('问题$r', r));
        if (r < 10) history.add(_ai('回复$r', r));
      }
      factory.tokensForNew = ['新回复'];
      await client.generateResponse(history).join();
      expect(summarizer.lastPrevious, isEmpty);

      summarizer.result = '第二轮摘要';
      await client
          .generateResponse(
              [...history, _ai('新回复', 10), _user('问题11', 11)])
          .join();

      expect(summarizer.callCount, 2);
      expect(summarizer.lastPrevious, '摘要内容'); // 旧摘要进入合并入参
      final rebuilt = factory.created.last;
      expect(
        rebuilt.ops.where((op) => op.startsWith('system:')).last,
        'system:【此前对话摘要】\n第二轮摘要',
      );
    });

    test('消息数不超过保底：不触发压缩（无移出、不调摘要器、不重建）', () async {
      final factory = _KvSessionFactory();
      final summarizer = _FakeSummarizer();
      final client = _tightClient(factory: factory, summarizer: summarizer);
      await client.initialize();

      factory.tokensForNew = ['回复A'];
      await client.generateResponse([_welcome, _user('问题1', 1)]).join();

      expect(summarizer.callCount, 0);
      expect(factory.created.length, 1); // 未重建
      expect(factory.created.single.ops.contains('user:问题1'), isTrue);
    });

    test('压缩：摘要器失败回落纯丢弃，生成不受影响', () async {
      final factory = _KvSessionFactory();
      final summarizer = _FakeSummarizer()..throwOnCall = StateError('boom');
      final client = _tightClient(factory: factory, summarizer: summarizer);
      await client.initialize();

      final history = <ChatMessage>[_welcome];
      for (var r = 1; r <= 10; r++) {
        history.add(_user('问题$r', r));
        if (r < 10) history.add(_ai('回复$r', r));
      }
      factory.tokensForNew = ['新回复'];
      final out = await client.generateResponse(history).join();

      expect(out, '新回复');
      expect(summarizer.callCount, 1);
      // 回落：无摘要卡，只有人设一条 system
      final rebuilt = factory.created.last;
      expect(rebuilt.ops.where((op) => op.startsWith('system:')).length, 1);
      expect(rebuilt.ops.contains('assistant:回复9'), isTrue);
      expect(rebuilt.ops.contains('user:问题10'), isTrue);
    });

    test('think 标签剥离：标签内不输出，标签后正常流式', () async {
      final factory = _KvSessionFactory();
      final client = LocalChatClient(kvSessionFactory: factory.call);
      await client.initialize();

      factory.created.single.tokens = [
        '<think>推理中',
        '的内容</think>',
        '答案',
        '!',
      ];
      final collected =
          await client.generateResponse([_welcome, _user('问题1', 1)]).toList();

      expect(collected, ['答案', '!']);
      expect(factory.created.single.ops.last, 'assistant:答案!');
    });

    test('取消：半截回复不登记，下一轮 diff 跳过该条 AI 历史', () async {
      final factory = _KvSessionFactory();
      final client = LocalChatClient(kvSessionFactory: factory.call);
      await client.initialize();

      final kv = factory.created.single;
      // 带 think 标签 → 闭合后 token 逐段流出，才能在流中途取消
      kv.tokens = ['<think>x</think>', '部分', '后半'];
      kv.pauseBetweenTokens = true;

      final collected = <String>[];
      final sub = client
          .generateResponse([_welcome, _user('问题1', 1)])
          .listen(collected.add);
      while (collected.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      await sub.cancel();
      await _settle();

      expect(collected, ['部分']);
      // 生成中断：assistant 未登记 KV 会话
      expect(kv.ops.contains('assistant:部分'), isFalse);
      expect(kv.ops.contains('assistant:部分后半'), isFalse);

      // 下一轮：历史含上轮半截 AI 消息，应被跳过，只 append 新用户消息
      kv.tokens = ['回复2'];
      final out2 = await client
          .generateResponse(
              [_welcome, _user('问题1', 1), _ai('部分', 1), _user('问题2', 2)])
          .join();

      expect(out2, '回复2');
      expect(kv.ops.contains('user:问题2'), isTrue);
      expect(kv.ops.contains('assistant:部分'), isFalse);
      expect(kv.ops.contains('assistant:回复2'), isTrue);
    });

    test('生成失败：yield 兜底文案，下一轮 diff 跳过该条 AI 历史', () async {
      final factory = _KvSessionFactory();
      final client = LocalChatClient(kvSessionFactory: factory.call);
      await client.initialize();

      final kv = factory.created.single;
      kv.throwOnGenerate = StateError('boom');

      const failureText = '\n\n[助手暂时无法回应，请稍后再试]';
      final out =
          await client.generateResponse([_welcome, _user('问题1', 1)]).join();
      expect(out, failureText);
      // 失败未登记 assistant（本轮也没有其它 assistant 消息）
      expect(
        kv.ops.where((op) => op.startsWith('assistant:')).length,
        0,
      );

      kv.throwOnGenerate = null;
      kv.tokens = ['恢复'];
      final out2 = await client
          .generateResponse([
            _welcome,
            _user('问题1', 1),
            _ai(failureText, 1),
            _user('问题2', 2),
          ])
          .join();

      expect(out2, '恢复');
      expect(kv.ops.contains('assistant:$failureText'), isFalse);
      expect(kv.ops.contains('assistant:恢复'), isTrue);
    });

    test('context-full 自愈：强制重建只留最后 4 条，下一轮可用', () async {
      final factory = _KvSessionFactory();
      final client = LocalChatClient(kvSessionFactory: factory.call);
      await client.initialize();

      // 造 6 轮追问（合格历史 11 条：5 组完整问答 + 尾部问题6）
      final history = <ChatMessage>[_welcome];
      for (var r = 1; r <= 5; r++) {
        history
          ..add(_user('问题$r', r))
          ..add(_ai('回复$r', r));
      }
      history.add(_user('问题6', 6));

      final kv = factory.created.single;
      kv.throwOnGenerate = const LlamaDecodeException(
        0,
        'context full at pos=4095 / nCtx=4096; '
        'set Request.shiftPolicy = ContextShiftPolicy.auto to shift or stop earlier',
      );

      final out = await client.generateResponse(history).join();
      expect(out, '\n\n[助手暂时无法回应，请稍后再试]');

      // 自愈重建：旧 KV 会话 dispose，新 KV 会话只含最后 4 条（回复4..问题6）
      expect(factory.created.length, 2);
      expect(factory.created.first.ops.last, 'dispose');
      final healed = factory.created.last;
      final chatOps = healed.ops
          .where((op) => op.startsWith('user:') || op.startsWith('assistant:'))
          .toList();
      expect(chatOps, [
        'assistant:回复4',
        'user:问题5',
        'assistant:回复5',
        'user:问题6',
      ]);

      // 下一轮在新 KV 会话上正常生成
      healed.tokens = ['恢复'];
      final out2 = await client
          .generateResponse(
              [...history, _ai('\n\n[助手暂时无法回应，请稍后再试]', 6), _user('问题7', 7)])
          .join();
      expect(out2, '恢复');
      expect(healed.ops.contains('user:问题7'), isTrue);
    });

    test('dispose：KV 会话释放且不可再生成', () async {
      final factory = _KvSessionFactory();
      final client = LocalChatClient(kvSessionFactory: factory.call);
      await client.initialize();
      expect(client.isReady, isTrue);

      client.dispose();
      expect(client.isReady, isFalse);
      expect(factory.created.single.ops.contains('dispose'), isTrue);
    });

    test('构造期校验：engine 与 kvSessionFactory 均缺省时抛 ArgumentError', () {
      expect(() => LocalChatClient(), throwsArgumentError);
    });

    test('kvSessionFactory-only（无摘要引擎）：压缩回落纯丢弃，生成不受阻', () async {
      final factory = _KvSessionFactory();
      // 预算 0 强制收缩；不注入 summarizer/engine
      final client = _tightClient(factory: factory);
      await client.initialize();

      factory.tokensForNew = ['新回复'];
      final out = await client
          .generateResponse(
              [_welcome, _user('问题1', 1), _ai('回复1', 1), _user('问题2', 2)])
          .join();
      expect(out, '新回复');

      // 压缩仍发生（KV 会话重建），只是 evicted 被纯丢弃（无摘要卡）
      expect(factory.created.length, 2);
      expect(factory.created.first.ops.last, 'dispose');
      final rebuilt = factory.created.last;
      expect(
        rebuilt.ops.where((op) => op.startsWith('system:')).length,
        1, // 只有人设，无摘要卡
      );
      expect(rebuilt.ops.contains('user:问题2'), isTrue);
    });
  });
}
