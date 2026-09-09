import 'package:flutter_test/flutter_test.dart';
import 'package:zhixing_ai/core/models/chat_models.dart';
import 'package:zhixing_ai/core/models/dashboard_models.dart';
import 'package:zhixing_ai/features/chat/engine/local_chat_client.dart';

/// LocalChatClient 单元测试（fake Session 注入，不触碰真实 llama）
///
/// 覆盖：增量 diff append、消费条数推进、去重改写仅 session 侧、
/// 截断重建（mirror 保留最近 12 条）、think 标签剥离、
/// 取消/失败时不登记 assistant 且下一轮 diff 跳过。

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

  /// 新建 session 预置的生成 tokens（截断重建发生在 generateResponse 内部，
  /// 无法在调用前拿到新 session 实例逐个设置）。
  List<String> tokensForNew = const [];

  Future<ChatSession> call() async {
    if (throwOnCreate != null) throw throwOnCreate!;
    final s = _FakeSession()..tokens = tokensForNew;
    created.add(s);
    return s;
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
    test('未初始化时 generateResponse 返回回退文案', () async {
      final client = LocalChatClient();
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

    test('截断：超过阈值时 session 重建，mirror 保留最近 12 条', () async {
      final factory = _SessionFactory();
      final client = LocalChatClient(
        sessionFactory: factory.call,
        truncateThreshold: 0, // 强制每次调用后触发截断
      );
      await client.initialize();

      final history = <ChatMessage>[_welcome];
      for (var r = 1; r <= 10; r++) {
        history.add(_user('问题$r', r));
        if (r < 10) history.add(_ai('回复$r', r)); // 尾部保持用户消息
      }
      // 20 条历史：welcome + 9 对完整问答 + 尾部问题10

      factory.tokensForNew = ['新回复']; // 截断重建后的新 session 用
      await client.generateResponse(history).join();

      expect(factory.created.length, 2); // 重建了一次 session
      expect(factory.created.first.ops.last, 'dispose');

      final rebuilt = factory.created.last;
      // system + 最近 12 条 mirror（回复4..问题10）+ generate + 新回复登记
      expect(rebuilt.ops.first, startsWith('system:'));
      expect(
        rebuilt.ops
            .where((op) => op.startsWith('user:') || op.startsWith('assistant:'))
            .toList(),
        [
          'assistant:回复4',
          'user:问题5',
          'assistant:回复5',
          'user:问题6',
          'assistant:回复6',
          'user:问题7',
          'assistant:回复7',
          'user:问题8',
          'assistant:回复8',
          'user:问题9',
          'assistant:回复9',
          'user:问题10',
          'assistant:新回复', // 生成完成后的登记（发生在重建后的 session 上）
        ],
      );
      expect(rebuilt.ops.contains('generate:2048'), isTrue);
      expect(rebuilt.ops.last, 'assistant:新回复');
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

    test('dispose：session 释放且不可再生成', () async {
      final factory = _SessionFactory();
      final client = LocalChatClient(sessionFactory: factory.call);
      await client.initialize();
      expect(client.isReady, isTrue);

      client.dispose();
      expect(client.isReady, isFalse);
      expect(factory.created.single.ops.contains('dispose'), isTrue);
    });
  });
}
