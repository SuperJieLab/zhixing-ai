import 'package:flutter_test/flutter_test.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;
import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/data/models/dashboard_models.dart';
import 'package:zhixing_ai/features/chat/engine/local_chat_client.dart';

/// LocalChatClient 单元测试（fake Session 注入，不触碰真实 llama）
///
/// 覆盖：增量 diff append、消费条数推进、去重改写仅 session 侧、
/// 截断重建（预算窗口）、think 标签剥离、
/// 取消/失败时不登记 assistant 且下一轮 diff 跳过、context-full 自愈。

class _FakeSession implements ChatSession {
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

class _SessionFactory {
  final List<_FakeSession> created = [];
  Object? throwOnCreate;

  /// 新建 session 预置的生成 tokens（压缩重建发生在 generateResponse 内部，
  /// 无法在调用前拿到新 session 实例逐个设置）。
  List<String> tokensForNew = const [];

  Future<ChatSession> call() async {
    if (throwOnCreate != null) throw throwOnCreate!;
    final s = _FakeSession()..tokens = tokensForNew;
    created.add(s);
    return s;
  }
}

class _FakeSummarizer {
  int callCount = 0;
  String? lastPrevious;
  List<({String role, String content})>? lastDropped;
  Object? throwOnCall;
  String result = '摘要内容';

  Future<String> call(String previousSummary,
      List<({String role, String content})> dropped) async {
    callCount++;
    lastPrevious = previousSummary;
    lastDropped = dropped;
    if (throwOnCall != null) throw throwOnCall!;
    return result;
  }
}

const _welcome = ChatMessage(role: MessageRole.ai, content: '欢迎语', round: 0);

ChatMessage _user(String content, int round) =>
    ChatMessage(role: MessageRole.user, content: content, round: round);

ChatMessage _ai(String content, int round) =>
    ChatMessage(role: MessageRole.ai, content: content, round: round);

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('LocalChatClient', () {
    test('默认阈值 = contextInputBudget（nCtx − 生成上限 − 余量）', () {
      final client = LocalChatClient(sessionFactory: _SessionFactory().call);
      expect(client.truncateThreshold, AppConstants.localInputBudget);
    });

    test('未初始化时 generateResponse 返回回退文案', () async {
      final client = LocalChatClient(sessionFactory: _SessionFactory().call);
      expect(client.isReady, isFalse);

      final out = await client.generateResponse([_welcome]).join();
      expect(out, '助手尚在准备中，请稍后再来。');
    });

    test('initialize 成功 → isReady；goals 注入系统提示词', () async {
      final factory = _SessionFactory();
      final client = LocalChatClient(sessionFactory: factory.call);

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
      final factory = _SessionFactory()..throwOnCreate = StateError('no model');
      final client = LocalChatClient(sessionFactory: factory.call);

      expect(await client.initialize(), isFalse);
      expect(client.isReady, isFalse);
    });

    test('首次调用完成全量 seed：欢迎语 + 用户消息入 session，生成后登记回复', () async {
      final factory = _SessionFactory();
      final client = LocalChatClient(sessionFactory: factory.call);
      await client.initialize();

      factory.created.single.tokens = ['回复A'];
      final out = await client
          .generateResponse([_welcome, _user('问题1', 1)])
          .join();

      expect(out, '回复A');
      expect(
        factory.created.single.ops,
        [
          'system:',
          'assistant:欢迎语',
          'user:问题1',
          'generate:2048',
          'assistant:回复A',
        ].map((op) => op == 'system:' ? startsWith('system:') : op),
      );
    });

    test('二次调用只 append 新增（增量 prefill，不重放已消费消息）', () async {
      final factory = _SessionFactory();
      final client = LocalChatClient(sessionFactory: factory.call);
      await client.initialize();

      final session = factory.created.single;
      session.tokens = ['回复A'];
      await client.generateResponse([_welcome, _user('问题1', 1)]).join();

      session.tokens = ['回复B'];
      await client
          .generateResponse(
              [_welcome, _user('问题1', 1), _ai('回复A', 1), _user('问题2', 2)])
          .join();

      // 已消费的欢迎语/问题1 不重复 append
      expect(
        session.ops.where((op) => op == 'user:问题1').length,
        1,
      );
      expect(
        session.ops.where((op) => op == 'assistant:欢迎语').length,
        1,
      );
      // 上一轮回复已在生成时登记：历史里的 回复A 不得再次 append
      expect(
        session.ops.where((op) => op == 'assistant:回复A').length,
        1,
      );
      // 新增的用户消息 + 生成完成后的 assistant 登记
      expect(session.ops.contains('user:问题2'), isTrue);
      expect(session.ops.contains('assistant:回复B'), isTrue);
    });

    test('去重：相邻相同问题在 session 侧改写（mirror 不受影响）', () async {
      final factory = _SessionFactory();
      final client = LocalChatClient(sessionFactory: factory.call);
      await client.initialize();

      final session = factory.created.single;
      session.tokens = ['回复A'];
      await client.generateResponse([_welcome, _user('目标A', 1)]).join();

      session.tokens = ['回复B'];
      await client
          .generateResponse(
              [_welcome, _user('目标A', 1), _ai('回复A', 1), _user('目标A', 2)])
          .join();

      expect(
        session.ops.contains('user:目标A（请从不同的角度回答，不要重复之前的观点）'),
        isTrue,
      );
      // 相同问题未入去重窗口：不会出现第二次裸 addUser('目标A') 之外的改写异常
      expect(session.ops.contains('user:目标A'), isTrue); // 首次调用
    });

    test('压缩：超阈值时预算装窗重建，移出消息进摘要卡', () async {
      final factory = _SessionFactory();
      final summarizer = _FakeSummarizer();
      final client = LocalChatClient(
        sessionFactory: factory.call,
        summarizer: summarizer.call,
        truncateThreshold: 0, // 强制触发压缩
      );
      await client.initialize();

      final history = <ChatMessage>[_welcome];
      for (var r = 1; r <= 10; r++) {
        history.add(_user('问题$r', r));
        if (r < 10) history.add(_ai('回复$r', r)); // 尾部保持用户消息
      }
      // 20 条历史：welcome + 9 对完整问答 + 尾部问题10

      factory.tokensForNew = ['新回复']; // 压缩重建后的新 session 用
      await client.generateResponse(history).join();

      expect(factory.created.length, 2); // 重建了一次 session
      expect(factory.created.first.ops.last, 'dispose');

      // 摘要器被调一次：旧摘要为空，dropped = 除保底 2 条外的全部
      expect(summarizer.callCount, 1);
      expect(summarizer.lastPrevious, isEmpty);
      expect(summarizer.lastDropped!.length, 18);
      expect(
        summarizer.lastDropped!.first,
        (role: 'ai', content: '欢迎语'),
      );

      final rebuilt = factory.created.last;
      // 两条 system：人设 + 摘要卡
      expect(rebuilt.ops.where((op) => op.startsWith('system:')).length, 2);
      expect(
        rebuilt.ops.where((op) => op.startsWith('system:')).last,
        'system:【此前对话摘要】\n摘要内容',
      );
      // 预算装窗（阈值 0 → 仅保底最后 2 条）+ 生成登记
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
      final factory = _SessionFactory();
      final summarizer = _FakeSummarizer();
      final client = LocalChatClient(
        sessionFactory: factory.call,
        summarizer: summarizer.call,
        truncateThreshold: 0,
      );
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

    test('压缩：消息不超保底（mirror ≤ 2）时仅重建，不调摘要器', () async {
      final factory = _SessionFactory();
      final summarizer = _FakeSummarizer();
      final client = LocalChatClient(
        sessionFactory: factory.call,
        summarizer: summarizer.call,
        truncateThreshold: 0,
      );
      await client.initialize();

      factory.tokensForNew = ['回复A'];
      await client.generateResponse([_welcome, _user('问题1', 1)]).join();

      expect(summarizer.callCount, 0);
      expect(factory.created.length, 2); // 仅重建
      final rebuilt = factory.created.last;
      expect(rebuilt.ops.where((op) => op.startsWith('system:')).length, 1);
      expect(rebuilt.ops.contains('assistant:欢迎语'), isTrue);
      expect(rebuilt.ops.contains('user:问题1'), isTrue);
    });

    test('压缩：摘要器失败回落纯丢弃，生成不受影响', () async {
      final factory = _SessionFactory();
      final summarizer = _FakeSummarizer()..throwOnCall = StateError('boom');
      final client = LocalChatClient(
        sessionFactory: factory.call,
        summarizer: summarizer.call,
        truncateThreshold: 0,
      );
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
      final factory = _SessionFactory();
      final client = LocalChatClient(sessionFactory: factory.call);
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
      final factory = _SessionFactory();
      final client = LocalChatClient(sessionFactory: factory.call);
      await client.initialize();

      final session = factory.created.single;
      // 带 think 标签 → 闭合后 token 逐段流出，才能在流中途取消
      session.tokens = ['<think>x</think>', '部分', '后半'];
      session.pauseBetweenTokens = true;

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
      // 生成中断：assistant 未登记 session
      expect(session.ops.contains('assistant:部分'), isFalse);
      expect(session.ops.contains('assistant:部分后半'), isFalse);

      // 下一轮：历史含上轮半截 AI 消息，应被跳过，只 append 新用户消息
      session.tokens = ['回复2'];
      final out2 = await client
          .generateResponse(
              [_welcome, _user('问题1', 1), _ai('部分', 1), _user('问题2', 2)])
          .join();

      expect(out2, '回复2');
      expect(session.ops.contains('user:问题2'), isTrue);
      expect(session.ops.contains('assistant:部分'), isFalse);
      expect(session.ops.contains('assistant:回复2'), isTrue);
    });

    test('生成失败：yield 兜底文案，下一轮 diff 跳过该条 AI 历史', () async {
      final factory = _SessionFactory();
      final client = LocalChatClient(sessionFactory: factory.call);
      await client.initialize();

      final session = factory.created.single;
      session.throwOnGenerate = StateError('boom');

      final out =
          await client.generateResponse([_welcome, _user('问题1', 1)]).join();
      expect(out, '\n\n[助手暂时无法回应，请稍后再试]');
      expect(
        session.ops.where((op) => op.startsWith('assistant:')).length,
        1, // 只有欢迎语
      );

      session.throwOnGenerate = null;
      session.tokens = ['恢复'];
      final out2 = await client
          .generateResponse([
            _welcome,
            _user('问题1', 1),
            _ai('\n\n[助手暂时无法回应，请稍后再试]', 1),
            _user('问题2', 2),
          ])
          .join();

      expect(out2, '恢复');
      expect(
        session.ops.contains('assistant:\n\n[助手暂时无法回应，请稍后再试]'),
        isFalse,
      );
      expect(session.ops.contains('assistant:恢复'), isTrue);
    });

    test('context-full 自愈：强制重建只留最后 4 条，下一轮可用', () async {
      final factory = _SessionFactory();
      final client = LocalChatClient(sessionFactory: factory.call);
      await client.initialize();

      // 造 6 轮完整问答（mirror 12 条：欢迎语 + 5.5 组）
      final history = <ChatMessage>[_welcome];
      for (var r = 1; r <= 5; r++) {
        history
          ..add(_user('问题$r', r))
          ..add(_ai('回复$r', r));
      }
      history.add(_user('问题6', 6));

      final session = factory.created.single;
      session.throwOnGenerate = const LlamaDecodeException(
        0,
        'context full at pos=4095 / nCtx=4096; '
        'set Request.shiftPolicy = ContextShiftPolicy.auto to shift or stop earlier',
      );

      final out = await client.generateResponse(history).join();
      expect(out, '\n\n[助手暂时无法回应，请稍后再试]');

      // 自愈重建：旧 session dispose，新 session 只含最后 4 条（回复4..问题6）
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

      // 下一轮在新 session 上正常生成
      healed.tokens = ['恢复'];
      final out2 = await client
          .generateResponse(
              [...history, _ai('\n\n[助手暂时无法回应，请稍后再试]', 6), _user('问题7', 7)])
          .join();
      expect(out2, '恢复');
      expect(healed.ops.contains('user:问题7'), isTrue);
    });

    test('dispose：session 释放且不可再生成', () async {
      final factory = _SessionFactory();
      final client = LocalChatClient(sessionFactory: factory.call);
      await client.initialize();
      expect(client.isReady, isTrue);

      client.dispose();
      expect(client.isReady, isFalse);
      expect(factory.created.single.ops.contains('dispose'), isTrue);
    });

    test('构造期校验：engine 与 sessionFactory 均缺省时抛 ArgumentError', () {
      expect(() => LocalChatClient(), throwsArgumentError);
    });

    test('sessionFactory-only（无摘要引擎）：压缩回落纯丢弃，生成不受阻', () async {
      final factory = _SessionFactory();
      // threshold=0 强制每轮触发压缩；不注入 summarizer/engine
      final client = LocalChatClient(
        sessionFactory: factory.call,
        truncateThreshold: 0,
      );
      await client.initialize();

      factory.tokensForNew = ['新回复'];
      final out = await client
          .generateResponse([_welcome, _user('问题1', 1)])
          .join();
      expect(out, '新回复');

      // 压缩仍发生（session 重建），只是 dropped 被纯丢弃（无摘要卡）
      expect(factory.created.length, 2);
      expect(factory.created.first.ops.last, 'dispose');
      final rebuilt = factory.created.last;
      expect(
        rebuilt.ops
            .where((op) => op.startsWith('system:') || op.startsWith('摘要'))
            .toList()
            .length,
        1, // 只有原 system 提示词，无摘要卡
      );
    });
  });
}
