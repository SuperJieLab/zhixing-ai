import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/context/context_assembly.dart';
import 'package:zhixing_ai/core/llm/generation/generation.dart';
import 'package:zhixing_ai/core/llm/llm.dart';
import 'package:zhixing_ai/core/model_gateway.dart';

/// 可编程 fake 补全面（透传验证用）。
class _FakeLlm implements Llm {
  final List<({String system, String user, int? maxTokens})> askCalls = [];
  int stopCalls = 0;
  final ValueNotifier<LlmReadiness> readinessNotifier =
      ValueNotifier<LlmReadiness>(const LlmReadiness.ready());

  @override
  Future<String> ask({
    required String system,
    required String user,
    int? maxTokens,
  }) async {
    askCalls.add((system: system, user: user, maxTokens: maxTokens));
    return 'ok';
  }

  @override
  Future<Map<String, dynamic>?> askJson({
    required String system,
    required String user,
    int? maxTokens,
  }) =>
      ask(system: system, user: user, maxTokens: maxTokens)
          .then((_) => <String, dynamic>{});

  @override
  void stop() => stopCalls++;

  @override
  bool get isReady => readinessNotifier.value.phase == LlmPhase.ready;

  @override
  ValueListenable<LlmReadiness> get readiness => readinessNotifier;

  @override
  Future<void> ensureReady() async {}
}

/// 脚本化 fake 转换段：记录装配入参与状态实例、可脚本化装配结果与溢出。
class _FakePolicy implements ContextPolicy {
  final List<List<ChatMessage>> assembleCalls = [];
  ContextState? lastState;
  int overflowCalls = 0;

  /// 第 n 次装配（0 起）返回什么；缺省原样透传历史。
  AssembledContext Function(int callIndex)? build;

  /// 装配时对状态执行的副作用（模拟真实策略的挤出/摘要写入）。
  void Function(ContextState state)? onAssemble;

  @override
  Future<AssembledContext> assemble(
    List<ChatMessage> history, {
    required ContextState state,
    String systemPrompt = '',
  }) async {
    final index = assembleCalls.length;
    assembleCalls.add(history);
    lastState = state;
    onAssemble?.call(state);
    return build?.call(index) ?? AssembledContext(messages: history);
  }

  @override
  void handleOverflow(ContextState state) {
    overflowCalls++;
    state.pendingForceKeep = 2; // 模拟真实策略：置位强制收缩
  }
}

/// 脚本化 fake 交付段：记录 deliver / prime 入参，可脚本化溢出与异常。
class _FakeDelivery implements ChatGeneration {
  final List<({AssembledContext ctx, String systemPrompt})> delivered = [];
  final List<({AssembledContext ctx, String systemPrompt, bool nudgeTail})>
      primed = [];
  int stopCalls = 0;

  /// 交付时抛出的异常（null = 正常）。抛 [LlmContextOverflowException] 即模拟
  /// 端侧 context full。
  Object? throwOnDeliver;
  List<String> tokens = const [];

  @override
  bool get isReady => true;

  @override
  Future<void> ensureReady() async {}

  @override
  Stream<String> deliver(
    AssembledContext assembled, {
    required String systemPrompt,
    bool nudgeTail = true,
  }) async* {
    delivered.add((ctx: assembled, systemPrompt: systemPrompt));
    final error = throwOnDeliver;
    if (error != null) throw error;
    for (final t in tokens) {
      yield t;
    }
  }

  @override
  void prime(
    AssembledContext assembled, {
    required String systemPrompt,
    bool nudgeTail = true,
  }) {
    primed.add(
        (ctx: assembled, systemPrompt: systemPrompt, nudgeTail: nudgeTail));
  }

  @override
  void stop() => stopCalls++;

  @override
  void dispose() {}
}

ChatMessage user(String content) => ChatMessage(
      role: MessageRole.user,
      content: content,
      round: 1,
    );

void main() {
  late _FakeLlm llm;
  late _FakePolicy policy;
  late _FakeDelivery delivery;
  late ValueNotifier<ChatMode> modeSource;
  late ModelGateway gateway;

  setUp(() {
    llm = _FakeLlm();
    policy = _FakePolicy();
    delivery = _FakeDelivery();
    modeSource = ValueNotifier<ChatMode>(ChatMode.local);
    gateway = ModelGateway(
      llm: llm,
      modeSource: modeSource,
      policyFactory: (_) => policy,
      deliveryFactory: () => delivery,
    );
    addTearDown(gateway.dispose);
  });

  group('对话面：编排（自 LlmService.converse 平移）', () {
    test('串联：先装配再交付，人设原样透传，token 按序产出', () async {
      delivery.tokens = ['你', '好'];
      final history = [user('q')];

      final out = await gateway
          .converse(history, systemPrompt: '人设X')
          .toList();

      expect(out, ['你', '好']);
      expect(policy.assembleCalls.single, same(history)); // 业务列表原样进转换段
      expect(policy.lastState, isNotNull); // 状态实例由网关持有并传入
      expect(delivery.delivered.single.systemPrompt, '人设X');
      expect(delivery.primed, isEmpty);
    });

    test('交付实例稳定：每轮经工厂取得同一实例（端侧会话不复建）', () async {
      delivery.tokens = ['一'];
      await gateway.converse([user('a')], systemPrompt: 's').toList();
      delivery.tokens = ['二'];
      await gateway.converse([user('b')], systemPrompt: 's').toList();

      expect(delivery.delivered, hasLength(2)); // 同一 fake 实例被复用
    });

    test('溢出自愈：承接 → 强制收缩 → 重装 → prime(nudgeTail:false) → 兜底文案',
        () async {
      final healed = AssembledContext(messages: [user('q2')]);
      var call = 0;
      policy.build = (_) {
        call++;
        if (call == 1) {
          // 首轮装配正常，交付时才撑爆
          delivery.throwOnDeliver = const LlmContextOverflowException();
          return AssembledContext(messages: [user('q1')]);
        }
        return healed; // 自愈后的重装结果
      };

      final out =
          await gateway.converse([user('q1')], systemPrompt: 's').toList();

      expect(policy.overflowCalls, 1);
      expect(delivery.primed, hasLength(1));
      expect(delivery.primed.single.nudgeTail, isFalse); // 二次重放不做尾部去重
      expect(identical(delivery.primed.single.ctx, healed), isTrue);
      expect(out, [kLlmFailureReply]); // 本轮以兜底文案收尾
      expect(delivery.delivered, hasLength(1)); // 生成只发生一次
    });

    test('自愈重放失败不影响兜底文案收尾', () async {
      delivery.throwOnDeliver = const LlmContextOverflowException();
      policy.build = (_) => AssembledContext(messages: [user('q')]);

      final out =
          await gateway.converse([user('q')], systemPrompt: 's').toList();

      expect(out, [kLlmFailureReply]); // 自愈失败被吞（网关记日志），兜底仍可达
    });
  });

  group('对话面：状态归属与模式切换（D2/D3）', () {
    test('状态实例由网关私有持有：同一实例跨轮复用', () async {
      await gateway.converse([user('a')], systemPrompt: 's').toList();
      final first = policy.lastState;
      await gateway.converse([user('b')], systemPrompt: 's').toList();

      expect(identical(policy.lastState, first), isTrue);
    });

    test('模式切换：窗口游标与记账清零，摘要正文保留', () async {
      // 首轮模拟真实策略：挤出 + 写摘要
      policy.onAssemble = (state) {
        state.k = 3;
        state.lastEligibleLength = 5;
        state.summary = '旧摘要正文';
      };
      await gateway.converse([user('a')], systemPrompt: 's').toList();
      expect(policy.lastState!.k, 3);

      modeSource.value = ChatMode.cloud; // D3：切换触发 resetWindow

      expect(policy.lastState!.k, 0);
      expect(policy.lastState!.lastEligibleLength, 0);
      expect(policy.lastState!.pendingForceKeep, isNull);
      expect(policy.lastState!.summary, '旧摘要正文'); // 摘要跨模式保留
    });

    test('策略按模式现选：工厂收到当前模式值', () async {
      final seenModes = <ChatMode>[];
      final gateway2 = ModelGateway(
        llm: llm,
        modeSource: modeSource,
        policyFactory: (mode) {
          seenModes.add(mode);
          return policy;
        },
        deliveryFactory: () => delivery,
      );
      addTearDown(gateway2.dispose);

      modeSource.value = ChatMode.local;
      await gateway2.converse([user('a')], systemPrompt: 's').toList();
      modeSource.value = ChatMode.cloud;
      await gateway2.converse([user('b')], systemPrompt: 's').toList();

      expect(seenModes, [ChatMode.local, ChatMode.cloud]);
    });
  });

  group('补全面：一行透传（D5）', () {
    test('ask 委派 llm.ask；stop / readiness / isReady 透传', () async {
      final out = await gateway.ask(system: 's', user: 'u');

      expect(out, 'ok');
      expect(llm.askCalls.single.user, 'u');
      expect(gateway.isReady, isTrue);
      expect(identical(gateway.readiness, llm.readiness), isTrue);

      gateway.stop();
      expect(llm.stopCalls, 1);
    });

    test('askJson 委派 llm.askJson', () async {
      await gateway.askJson(system: 's', user: 'u');
      expect(llm.askCalls.single.user, 'u');
    });
  });
}
