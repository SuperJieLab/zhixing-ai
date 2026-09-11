import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/data/models/dashboard_models.dart';
import 'package:zhixing_ai/features/chat/engine/context/context_policy.dart';
import 'package:zhixing_ai/features/chat/engine/client/local_chat_client.dart';
import 'package:zhixing_ai/features/chat/engine/context/local_context_policy.dart';

/// LocalChatClient 单元测试（fake ChatSession 注入，不触碰真实 llama）。
///
/// **核心不变量**：每轮 generateResponse 都是
/// `clear → system(人设) [→ system(摘要卡)] → 按装配结果全量重放 → generate`，
/// 且全生命周期只创建**一个** ChatSession。fake 只记录 ops，不模拟底层
/// `EngineChat` 的「自动登记回复」（客户端不得依赖该副作用）。
///
/// 覆盖：逐字重放、去重改写仅作用尾部、窗口收缩后重放、think 剥离、
/// 取消/失败后的下一轮、context-full 自愈、eventsToText 转换。
/// 装配本身的单测见 `context/*_test.dart`。

class _FakeChatSession implements ChatSession {
  final List<String> ops = [];
  List<String> tokens = const [];
  Object? throwOnGenerate;

  /// true 时每个 token 后让出一个事件循环（供取消测试在流中途稳定取消）。
  bool pauseBetweenTokens = false;

  @override
  void clear() => ops.add('clear');

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

class _ChatSessionFactory {
  final List<_FakeChatSession> created = [];
  Object? throwOnCreate;

  /// 全生命周期只应创建 1 个会话；断言 `created.length` 即锁定该不变量。
  Future<ChatSession> call() async {
    if (throwOnCreate != null) throw throwOnCreate!;
    final s = _FakeChatSession();
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
  required _ChatSessionFactory factory,
  ConversationSummarizer? summarizer,
}) =>
    LocalChatClient(
      sessionFactory: factory.call,
      policy: LocalContextPolicy(budget: 0, summarizer: summarizer),
    );

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

const _think = '<think>x</think>';

TokenEvent _token(String text) =>
    TokenEvent(id: 1, bytes: Uint8List(0), text: text, position: 0);

void main() {
  group('LocalChatClient', () {
    test('未初始化时 generateResponse 返回回退文案', () async {
      final client = LocalChatClient(sessionFactory: _ChatSessionFactory().call);
      expect(client.isReady, isFalse);

      final out = await client.generateResponse([_welcome]).join();
      expect(out, '助手尚在准备中，请稍后再来。');
    });

    test('initialize 成功 → isReady；goals 注入系统提示词', () async {
      final factory = _ChatSessionFactory();
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
      final factory = _ChatSessionFactory()
        ..throwOnCreate = StateError('no model');
      final client = LocalChatClient(sessionFactory: factory.call);

      expect(await client.initialize(), isFalse);
      expect(client.isReady, isFalse);
    });

    test('首轮：clear 开头，按装配结果全量重放（第 0 轮欢迎语被过滤）', () async {
      final factory = _ChatSessionFactory();
      final client = LocalChatClient(sessionFactory: factory.call);
      await client.initialize();

      final session = factory.created.single;
      session.tokens = ['回复A'];
      final out =
          await client.generateResponse([_welcome, _user('问题1', 1)]).join();

      expect(out, '回复A');
      // initialize 先注入人设；本轮重放以 clear 开头并重新放入人设
      expect(session.ops.first, startsWith('system:'));
      expect(session.ops.sublist(1), [
        'clear',
        startsWith('system:'),
        'user:问题1',
        'generate:2048',
      ]);
    });

    test('重放不变量：每轮全量重放、全生命周期仅一个会话', () async {
      final factory = _ChatSessionFactory();
      final client = LocalChatClient(sessionFactory: factory.call);
      await client.initialize();

      final session = factory.created.single;
      session.ops.clear();
      session.tokens = ['A'];
      await client.generateResponse([_welcome, _user('q1', 1)]).join();
      expect(session.ops, [
        'clear',
        startsWith('system:'),
        'user:q1',
        'generate:2048',
      ]);

      // 二次调用：历史全量重放（不是只补 diff）
      session.ops.clear();
      session.tokens = ['B'];
      await client
          .generateResponse(
              [_welcome, _user('q1', 1), _ai('A', 1), _user('q2', 2)])
          .join();
      expect(session.ops, [
        'clear',
        startsWith('system:'),
        'user:q1',
        'assistant:A',
        'user:q2',
        'generate:2048',
      ]);

      expect(factory.created.length, 1);
    });

    test('去重：仅尾部用户消息在重放时改写为换角度提示', () async {
      final factory = _ChatSessionFactory();
      final client = LocalChatClient(sessionFactory: factory.call);
      await client.initialize();

      final session = factory.created.single;
      session.tokens = ['回复A'];
      await client.generateResponse([_welcome, _user('目标A', 1)]).join();

      session.ops.clear();
      session.tokens = ['回复B'];
      await client
          .generateResponse(
              [_welcome, _user('目标A', 1), _ai('回复A', 1), _user('目标A', 2)])
          .join();

      expect(session.ops, [
        'clear',
        startsWith('system:'),
        'user:目标A', // 非尾部 → 不改写
        'assistant:回复A',
        'user:目标A（请从不同的角度回答，不要重复之前的观点）',
        'generate:2048',
      ]);
    });

    test('压缩：超预算时窗口收缩，移出消息进摘要卡，会话按新窗口重放', () async {
      final factory = _ChatSessionFactory();
      final summarizer = _FakeSummarizer();
      final client = _tightClient(factory: factory, summarizer: summarizer);
      await client.initialize();

      final session = factory.created.single;
      session.ops.clear();

      final history = <ChatMessage>[_welcome];
      for (var r = 1; r <= 10; r++) {
        history.add(_user('问题$r', r));
        if (r < 10) history.add(_ai('回复$r', r)); // 尾部保持用户消息
      }
      // 19 条合格历史（欢迎语被过滤）：9 对完整问答 + 尾部问题10

      session.tokens = ['新回复'];
      final out = await client.generateResponse(history).join();

      expect(out, '新回复');
      // 不再重建会话：全生命周期仅一个实例
      expect(factory.created.length, 1);

      // 摘要器被调一次：旧摘要为空，evicted = 除保底 2 条外的全部
      expect(summarizer.callCount, 1);
      expect(summarizer.lastPrevious, isEmpty);
      expect(summarizer.lastEvicted!.length, 17);
      expect(summarizer.lastEvicted!.first.content, '问题1');
      expect(summarizer.lastEvicted!.first.role, MessageRole.user);

      // 人设 + 摘要卡两条 system，随后按装窗结果（保底最后 2 条）重放
      expect(session.ops, [
        'clear',
        startsWith('system:'),
        'system:【此前对话摘要】\n摘要内容',
        'assistant:回复9',
        'user:问题10',
        'generate:2048',
      ]);
    });

    test('压缩递归压实：第二次压缩把旧摘要并入 summarizer 入参', () async {
      final factory = _ChatSessionFactory();
      final summarizer = _FakeSummarizer();
      final client = _tightClient(factory: factory, summarizer: summarizer);
      await client.initialize();

      final session = factory.created.single;
      final history = <ChatMessage>[_welcome];
      for (var r = 1; r <= 10; r++) {
        history.add(_user('问题$r', r));
        if (r < 10) history.add(_ai('回复$r', r));
      }
      session.tokens = ['新回复'];
      await client.generateResponse(history).join();
      expect(summarizer.lastPrevious, isEmpty);

      summarizer.result = '第二轮摘要';
      session.ops.clear();
      await client
          .generateResponse(
              [...history, _ai('新回复', 10), _user('问题11', 11)])
          .join();

      expect(summarizer.callCount, 2);
      expect(summarizer.lastPrevious, '摘要内容'); // 旧摘要进入合并入参
      expect(
        session.ops.where((op) => op.startsWith('system:')).last,
        'system:【此前对话摘要】\n第二轮摘要',
      );
      expect(factory.created.length, 1);
    });

    test('消息数不超过保底：不触发压缩（无移出、不调摘要器）', () async {
      final factory = _ChatSessionFactory();
      final summarizer = _FakeSummarizer();
      final client = _tightClient(factory: factory, summarizer: summarizer);
      await client.initialize();

      final session = factory.created.single;
      session.ops.clear();
      session.tokens = ['回复A'];
      await client.generateResponse([_welcome, _user('问题1', 1)]).join();

      expect(summarizer.callCount, 0);
      expect(factory.created.length, 1);
      // 只有人设一条 system（无摘要卡）
      expect(session.ops, [
        'clear',
        startsWith('system:'),
        'user:问题1',
        'generate:2048',
      ]);
    });

    test('压缩：摘要器失败回落纯丢弃，生成不受影响', () async {
      final factory = _ChatSessionFactory();
      final summarizer = _FakeSummarizer()..throwOnCall = StateError('boom');
      final client = _tightClient(factory: factory, summarizer: summarizer);
      await client.initialize();

      final session = factory.created.single;
      session.ops.clear();

      final history = <ChatMessage>[_welcome];
      for (var r = 1; r <= 10; r++) {
        history.add(_user('问题$r', r));
        if (r < 10) history.add(_ai('回复$r', r));
      }
      session.tokens = ['新回复'];
      final out = await client.generateResponse(history).join();

      expect(out, '新回复');
      expect(summarizer.callCount, 1);
      // 回落：无摘要卡，只有人设一条 system
      expect(session.ops.where((op) => op.startsWith('system:')).length, 1);
      expect(session.ops.contains('assistant:回复9'), isTrue);
      expect(session.ops.contains('user:问题10'), isTrue);
      expect(factory.created.length, 1);
    });

    test('think 标签剥离：标签内不输出，标签后正常流式', () async {
      final factory = _ChatSessionFactory();
      final client = LocalChatClient(sessionFactory: factory.call);
      await client.initialize();

      final session = factory.created.single;
      session.tokens = [
        '<think>推理中',
        '的内容</think>',
        '答案',
        '!',
      ];
      final collected =
          await client.generateResponse([_welcome, _user('问题1', 1)]).toList();

      expect(collected, ['答案', '!']);
      // 输出侧不做登记；本轮装配结果里也没有 assistant 条目
      expect(
        session.ops.where((op) => op.startsWith('assistant:')),
        isEmpty,
      );
    });

    test('取消：不登记半截回复；下一轮按业务列表重放该条 AI', () async {
      final factory = _ChatSessionFactory();
      final client = LocalChatClient(sessionFactory: factory.call);
      await client.initialize();

      final session = factory.created.single;
      // 带 think 标签 → 闭合后 token 逐段流出，才能在流中途取消
      session.tokens = [_think, '部分', '后半'];
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
      // 生成中断：客户端不登记 assistant
      expect(session.ops.where((op) => op.startsWith('assistant:')), isEmpty);

      session.ops.clear();
      session.pauseBetweenTokens = false;
      session.tokens = ['回复2'];
      final out2 = await client
          .generateResponse(
              [_welcome, _user('问题1', 1), _ai('部分', 1), _user('问题2', 2)])
          .join();

      expect(out2, '回复2');
      // 语义反转：不再"跳过"，而是按业务列表把该条半截 AI 原样重放
      expect(session.ops, [
        'clear',
        startsWith('system:'),
        'user:问题1',
        'assistant:部分',
        'user:问题2',
        'generate:2048',
      ]);
    });

    test('生成失败：yield 兜底文案；下一轮按业务列表重放该条 AI', () async {
      final factory = _ChatSessionFactory();
      final client = LocalChatClient(sessionFactory: factory.call);
      await client.initialize();

      final session = factory.created.single;
      session.throwOnGenerate = StateError('boom');

      const failureText = '\n\n[助手暂时无法回应，请稍后再试]';
      final out =
          await client.generateResponse([_welcome, _user('问题1', 1)]).join();
      expect(out, failureText);

      session.ops.clear();
      session.throwOnGenerate = null;
      session.tokens = ['恢复'];
      final out2 = await client
          .generateResponse([
            _welcome,
            _user('问题1', 1),
            _ai(failureText, 1),
            _user('问题2', 2),
          ])
          .join();

      expect(out2, '恢复');
      expect(session.ops, [
        'clear',
        startsWith('system:'),
        'user:问题1',
        'assistant:$failureText',
        'user:问题2',
        'generate:2048',
      ]);
    });

    test('context-full 自愈：强制收缩只留最后 4 条并按新窗口重放', () async {
      final factory = _ChatSessionFactory();
      final client = LocalChatClient(sessionFactory: factory.call);
      await client.initialize();

      // 造 6 轮追问（合格历史 11 条：5 组完整问答 + 尾部问题6）
      final history = <ChatMessage>[_welcome];
      for (var r = 1; r <= 5; r++) {
        history
          ..add(_user('问题$r', r))
          ..add(_ai('回复$r', r));
      }
      history.add(_user('问题6', 6));

      final session = factory.created.single;
      session.ops.clear();
      session.throwOnGenerate = const LlamaDecodeException(
        0,
        'context full at pos=4095 / nCtx=4096; '
        'set Request.shiftPolicy = ContextShiftPolicy.auto to shift or stop earlier',
      );

      final out = await client.generateResponse(history).join();
      expect(out, '\n\n[助手暂时无法回应，请稍后再试]');

      // 不重建会话
      expect(factory.created.length, 1);

      // 自愈段 = 最后一次 clear 之后的片段：硬收缩窗口（最后 4 条）
      final healedOps = session.ops.sublist(session.ops.lastIndexOf('clear'));
      expect(
        healedOps
            .where(
                (op) => op.startsWith('user:') || op.startsWith('assistant:'))
            .toList(),
        [
          'assistant:回复4',
          'user:问题5',
          'assistant:回复5',
          'user:问题6',
        ],
      );

      // 下一轮在同一会话上正常生成
      session.throwOnGenerate = null;
      session.tokens = ['恢复'];
      final out2 = await client
          .generateResponse([
            ...history,
            _ai('\n\n[助手暂时无法回应，请稍后再试]', 6),
            _user('问题7', 7),
          ])
          .join();
      expect(out2, '恢复');
      expect(session.ops.contains('user:问题7'), isTrue);
    });

    test('dispose：会话释放且不可再生成', () async {
      final factory = _ChatSessionFactory();
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
      final factory = _ChatSessionFactory();
      // 预算 0 强制收缩；不注入 summarizer/engine
      final client = _tightClient(factory: factory);
      await client.initialize();

      final session = factory.created.single;
      session.ops.clear();
      session.tokens = ['新回复'];
      final out = await client
          .generateResponse(
              [_welcome, _user('问题1', 1), _ai('回复1', 1), _user('问题2', 2)])
          .join();
      expect(out, '新回复');

      // 压缩仍发生（窗口收缩），evicted 被纯丢弃（无摘要卡）
      expect(factory.created.length, 1);
      expect(session.ops.where((op) => op.startsWith('system:')).length, 1);
      expect(session.ops.contains('user:问题2'), isTrue);
    });
  });

  group('eventsToText（SDK 事件流 → 文本 token 流）', () {
    test('TokenEvent 逐条输出；DoneEvent.trailingText 非空时补充', () async {
      final out = await eventsToText(Stream.fromIterable([
        _token('正文'),
        const DoneEvent(
          reason: StopMaxTokens(),
          generatedCount: 1,
          committedPosition: 1,
          trailingText: '残留片段',
        ),
      ])).toList();

      expect(out, ['正文', '残留片段']);
    });

    test('DoneEvent.trailingText 为空时不产生空事件', () async {
      final out = await eventsToText(Stream.fromIterable([
        _token('正文'),
        const DoneEvent(
          reason: StopMaxTokens(),
          generatedCount: 1,
          committedPosition: 1,
        ),
      ])).toList();

      expect(out, ['正文']);
    });

    test('ShiftEvent 被忽略（不参与文本流）', () async {
      final out = await eventsToText(Stream.fromIterable([
        const ShiftEvent(nKeep: 1, nDiscard: 2, newPosition: 3),
        _token('正文'),
      ])).toList();

      expect(out, ['正文']);
    });
  });
}
