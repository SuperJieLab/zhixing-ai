import 'package:flutter_test/flutter_test.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/llm/context_assembly.dart';
import 'package:zhixing_ai/core/llm/delivery/chat_delivery.dart';
import 'package:zhixing_ai/core/llm/delivery/local_delivery.dart';

/// 端侧交付单元测试（fake [ChatSession] 注入，不触碰真实 llama）。
///
/// **核心不变量**（2026-09-11 无状态重放四条，Task 3 迁移后仍成立）：
/// ① 每轮 `clear → system(人设) [→ system(摘要卡)] → 按装配结果全量重放 → generate`；
/// ② 引擎内列表 ≡ 装配结果（逐字），交付不持业务消息列表；
/// ③ assistant 条目均为 strip 后正文（think 不进重放）；
/// ④ 无任何「引擎状态与我方索引对齐」机制（全生命周期仅 1 个会话，靠 clear 重置）。
///
/// fake 只记录 ops，**不模拟**底层 `EngineChat` 的「自动登记回复」副作用——
/// 交付不得依赖它。装配（过滤 / 装窗 / 压缩）单测见
/// `test/core/llm/context_assembly_test.dart`；`context full` 的**自愈编排**在
/// 服务层（`test/core/llm/llm_service_test.dart`），本层只断言**抛出类型化信号**。

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

ChatMessage _user(String content, int round) =>
    ChatMessage(role: MessageRole.user, content: content, round: round);

ChatMessage _ai(String content, int round) =>
    ChatMessage(role: MessageRole.ai, content: content, round: round);

/// 直构装配结果：交付只消费结果，装配正确性由转换段自测。
AssembledContext _ctx(List<ChatMessage> messages, {String? summaryCard}) =>
    AssembledContext(messages: messages, summaryCard: summaryCard);

const _system = '人设S';

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

const _think = '<think>x</think>';

void main() {
  late _ChatSessionFactory factory;
  late LocalDelivery delivery;

  setUp(() {
    factory = _ChatSessionFactory();
    delivery = LocalDelivery(sessionFactory: factory.call);
  });

  group('LocalDelivery · 就绪态', () {
    test('未就绪时 deliver 返回回退文案', () async {
      expect(delivery.isReady, isFalse);

      final out = await delivery
          .deliver(_ctx([_user('q', 1)]), systemPrompt: _system)
          .join();

      expect(out, kLlmNotReadyReply);
    });

    test('ensureReady 建会话 → isReady；人设作为首条 system 注入', () async {
      await delivery.ensureReady();
      expect(delivery.isReady, isTrue);

      final session = factory.created.single;
      session.tokens = ['回复A'];
      final out = await delivery
          .deliver(_ctx([_user('问题1', 1)]), systemPrompt: _system)
          .join();

      expect(out, '回复A');
      expect(session.ops, ['clear', 'system:$_system', 'user:问题1', 'generate:2048']);
    });

    test('ensureReady 幂等：全生命周期仅创建一个会话', () async {
      await delivery.ensureReady();
      await delivery.ensureReady();

      expect(factory.created.length, 1);
      expect(delivery.isReady, isTrue);
    });

    test('ensureReady 工厂抛错 → 异常上抛且仍未就绪', () async {
      factory.throwOnCreate = StateError('no model');

      await expectLater(delivery.ensureReady(), throwsStateError);
      expect(delivery.isReady, isFalse);
    });

    test('dispose 后仍未就绪：释放会话、再 deliver 回退文案', () async {
      await delivery.ensureReady();
      expect(delivery.isReady, isTrue);

      delivery.dispose();

      expect(delivery.isReady, isFalse);
      expect(factory.created.single.ops.contains('dispose'), isTrue);
      final out = await delivery
          .deliver(_ctx([_user('q', 1)]), systemPrompt: _system)
          .join();
      expect(out, kLlmNotReadyReply);
    });
  });

  group('LocalDelivery · 无状态重放（不变量 ①②④）', () {
    test('每轮 clear 开头、逐字重放装配结果；历史全量重放而非补差', () async {
      await delivery.ensureReady();
      final session = factory.created.single;

      session.ops.clear();
      session.tokens = ['A'];
      await delivery
          .deliver(_ctx([_user('q1', 1)]), systemPrompt: _system)
          .join();
      expect(session.ops, ['clear', 'system:$_system', 'user:q1', 'generate:2048']);

      // 二次调用：历史全量重放（不是只补 diff）
      session.ops.clear();
      session.tokens = ['B'];
      await delivery
          .deliver(
              _ctx([_user('q1', 1), _ai('A', 1), _user('q2', 2)]),
              systemPrompt: _system)
          .join();
      expect(session.ops, [
        'clear',
        'system:$_system',
        'user:q1',
        'assistant:A',
        'user:q2',
        'generate:2048',
      ]);

      expect(factory.created.length, 1);
    });

    test('交付不持业务列表：第二轮给更短列表 → 引擎列表被完全替换', () async {
      await delivery.ensureReady();
      final session = factory.created.single;

      session.tokens = ['A'];
      await delivery
          .deliver(_ctx([_user('q1', 1), _ai('A', 1)]), systemPrompt: _system)
          .join();

      session.ops.clear();
      session.tokens = ['B'];
      await delivery
          .deliver(_ctx([_user('新话', 5)]), systemPrompt: _system)
          .join();

      // 无上一轮残留：clear 后只重放本轮装配结果
      expect(session.ops, [
        'clear',
        'system:$_system',
        'user:新话',
        'generate:2048',
      ]);
    });

    test('摘要卡紧随人设：两条 system，均排在消息之前', () async {
      await delivery.ensureReady();
      final session = factory.created.single;

      session.tokens = ['回复'];
      await delivery
          .deliver(
              _ctx([_user('q', 1)], summaryCard: '$kSummaryCardPrefix\n摘要内容'),
              systemPrompt: _system)
          .join();

      expect(session.ops, [
        'clear',
        'system:$_system',
        'system:$kSummaryCardPrefix\n摘要内容',
        'user:q',
        'generate:2048',
      ]);
    });

    test('空 content 的条目被跳过（不产生空消息）', () async {
      await delivery.ensureReady();
      final session = factory.created.single;

      session.tokens = ['回复'];
      await delivery
          .deliver(_ctx([_user('', 1), _user('q', 1)]), systemPrompt: _system)
          .join();

      expect(session.ops, ['clear', 'system:$_system', 'user:q', 'generate:2048']);
    });

    test('交付层不做过滤：round==0 也原样重放（过滤归转换段）', () async {
      await delivery.ensureReady();
      final session = factory.created.single;

      session.tokens = ['回复'];
      await delivery
          .deliver(
              _ctx([_ai('欢迎语', 0), _user('q', 1)]),
              systemPrompt: _system)
          .join();

      expect(session.ops, [
        'clear',
        'system:$_system',
        'assistant:欢迎语',
        'user:q',
        'generate:2048',
      ]);
    });
  });

  group('LocalDelivery · 尾部去重（交付内部状态）', () {
    test('仅尾部用户消息在重放时改写为换角度提示', () async {
      await delivery.ensureReady();
      final session = factory.created.single;

      session.tokens = ['回复A'];
      await delivery
          .deliver(_ctx([_user('目标A', 1)]), systemPrompt: _system)
          .join();

      // 同问再现（尾部）→ 改写
      session.ops.clear();
      session.tokens = ['回复B'];
      await delivery
          .deliver(
              _ctx([_user('目标A', 1), _ai('回复A', 1), _user('目标A', 2)]),
              systemPrompt: _system)
          .join();

      expect(session.ops, [
        'clear',
        'system:$_system',
        'user:目标A', // 非尾部 → 不改写
        'assistant:回复A',
        'user:目标A（请从不同的角度回答，不要重复之前的观点）',
        'generate:2048',
      ]);
    });

    test('prime（nudgeTail:false）不去重改写、不生成', () async {
      await delivery.ensureReady();
      final session = factory.created.single;

      session.tokens = ['回复A'];
      await delivery
          .deliver(_ctx([_user('目标A', 1)]), systemPrompt: _system)
          .join();

      session.ops.clear();
      delivery.prime(
          _ctx([_user('目标A', 1), _ai('回复A', 1), _user('目标A', 2)]),
          systemPrompt: _system,
          // 服务层自愈二次重放会显式关掉去重：isDuplicate 有状态且本轮已判定过
          nudgeTail: false);

      // 二次重放不再判定去重（isDuplicate 有状态，本轮已判定过）；且不触发生成
      expect(session.ops, [
        'clear',
        'system:$_system',
        'user:目标A',
        'assistant:回复A',
        'user:目标A',
      ]);
    });

    test('新会话首问（无摘要+单条消息）→ 清空判重窗口，同问不再误判为重复',
        () async {
      await delivery.ensureReady();
      final session = factory.created.single;

      // 会话 1：问「目标A」并得到回复（问题进入判重窗口）
      session.tokens = ['回复A'];
      await delivery
          .deliver(_ctx([_user('目标A', 1)]), systemPrompt: _system)
          .join();

      // 会话 2（新对话）：交付实现与 App 同寿命，仅摘要卡为 null 且窗口
      // 只剩 1 条 → 判定「新会话首问」→ 窗口重置；同样的首问不得被
      // 上一会话的历史误判为重复而改写。
      session.ops.clear();
      session.tokens = ['回复B'];
      await delivery
          .deliver(_ctx([_user('目标A', 1)]), systemPrompt: _system)
          .join();

      expect(session.ops, [
        'clear',
        'system:$_system',
        'user:目标A', // 未改写：跨会话窗口已重置
        'generate:2048',
      ]);
    });
  });

  group('LocalDelivery · 取回与 think 剥离', () {
    test('think 标签剥离：标签内不输出，标签后正常流式', () async {
      await delivery.ensureReady();
      final session = factory.created.single;
      session.tokens = ['<think>推理中', '的内容</think>', '答案', '!'];

      final collected =
          await delivery.deliver(_ctx([_user('问题1', 1)]), systemPrompt: _system).toList();

      expect(collected, ['答案', '!']);
      // 输出侧不做登记；重放里也没有 assistant 条目
      expect(session.ops.where((op) => op.startsWith('assistant:')), isEmpty);
    });

    test('非思考模式（无闭合标签）：缓冲内容即正文，兜底一次产出', () async {
      await delivery.ensureReady();
      factory.created.single.tokens = ['没有标签的', '正文'];

      final collected =
          await delivery.deliver(_ctx([_user('q', 1)]), systemPrompt: _system).toList();

      expect(collected, ['没有标签的正文']);
    });

    test('取消：不登记半截回复；下一轮按业务列表重放该条 AI', () async {
      await delivery.ensureReady();
      final session = factory.created.single;
      // 带 think 标签 → 闭合后 token 逐段流出，才能在流中途取消
      session.tokens = [_think, '部分', '后半'];
      session.pauseBetweenTokens = true;

      final collected = <String>[];
      final sub = delivery
          .deliver(_ctx([_user('问题1', 1)]), systemPrompt: _system)
          .listen(collected.add);
      while (collected.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      await sub.cancel();
      await _settle();

      expect(collected, ['部分']);
      expect(session.ops.where((op) => op.startsWith('assistant:')), isEmpty);

      session.ops.clear();
      session.pauseBetweenTokens = false;
      session.tokens = ['回复2'];
      final out2 = await delivery
          .deliver(
              _ctx([_user('问题1', 1), _ai('部分', 1), _user('问题2', 2)]),
              systemPrompt: _system)
          .join();

      expect(out2, '回复2');
      expect(session.ops, [
        'clear',
        'system:$_system',
        'user:问题1',
        'assistant:部分',
        'user:问题2',
        'generate:2048',
      ]);
    });

    test('生成失败：yield 兜底文案；下一轮按业务列表重放该条 AI', () async {
      await delivery.ensureReady();
      final session = factory.created.single;
      session.throwOnGenerate = StateError('boom');

      final out = await delivery
          .deliver(_ctx([_user('问题1', 1)]), systemPrompt: _system)
          .join();
      expect(out, kLlmFailureReply);

      session.ops.clear();
      session.throwOnGenerate = null;
      session.tokens = ['恢复'];
      final out2 = await delivery
          .deliver(
              _ctx([
                _user('问题1', 1),
                _ai(kLlmFailureReply, 1),
                _user('问题2', 2),
              ]),
              systemPrompt: _system)
          .join();

      expect(out2, '恢复');
      expect(session.ops, [
        'clear',
        'system:$_system',
        'user:问题1',
        'assistant:$kLlmFailureReply',
        'user:问题2',
        'generate:2048',
      ]);
    });
  });

  group('LocalDelivery · context full 信号（自愈编排归服务）', () {
    test('context full → 抛 LlmContextOverflowException，不自行收缩、不产出文案',
        () async {
      await delivery.ensureReady();
      final session = factory.created.single;
      session.throwOnGenerate = const LlamaDecodeException(
        0,
        'context full at pos=4095 / nCtx=4096; '
        'set Request.shiftPolicy = ContextShiftPolicy.auto to shift or stop earlier',
      );

      final collected = <String>[];
      Object? caught;
      try {
        await for (final t in delivery
            .deliver(_ctx([_user('问题6', 6)]), systemPrompt: _system)) {
          collected.add(t);
        }
      } catch (e) {
        caught = e;
      }

      expect(collected, isEmpty);
      expect(caught, isA<LlmContextOverflowException>());
      // 交付自身不重建会话、不追加额外重放段
      expect(factory.created.length, 1);
    });

    test('stop 为 no-op：本地中断靠消费方取消订阅，不改变会话/就绪态', () async {
      await delivery.ensureReady();

      delivery.stop();

      expect(delivery.isReady, isTrue);
      expect(factory.created.single.ops, isEmpty);
    });
  });
}
