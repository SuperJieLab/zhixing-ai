import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/data/repository/settings_repository.dart';
import 'package:zhixing_ai/core/llm/context_assembly.dart';
import 'package:zhixing_ai/core/llm/delivery/chat_delivery.dart';
import 'package:zhixing_ai/core/llm/llm_service.dart';

/// 记录调用的 fake 后端接缝（[SingleShotAsk] 形态）。
class _Recorder {
  final List<({String system, String user, int? maxTokens})> calls = [];
  String Function()? reply;
  Object? throwOnCall;

  Future<String> ask({
    required String system,
    required String user,
    int? maxTokens,
  }) async {
    calls.add((system: system, user: user, maxTokens: maxTokens));
    if (throwOnCall != null) throw throwOnCall!;
    return reply?.call() ?? '';
  }
}

/// 脚本化 fake 转换段：记录装配入参、返回定制的装配结果。
class _FakePolicy implements ContextPolicy {
  final List<List<ChatMessage>> assembleCalls = [];
  int overflowCalls = 0;

  /// 第 n 次装配（0 起）返回什么；缺省原样透传历史。
  AssembledContext Function(int callIndex)? build;

  /// 指定次数的装配抛错（验证自愈失败不影响兜底）。
  int? throwOnAssembleCallIndex;

  @override
  Future<AssembledContext> assemble(
    List<ChatMessage> history, {
    required ContextState state,
    String systemPrompt = '',
  }) async {
    final index = assembleCalls.length;
    assembleCalls.add(history);
    if (throwOnAssembleCallIndex == index) throw StateError('assemble boom');
    return build?.call(index) ?? AssembledContext(messages: history);
  }

  @override
  void handleOverflow(ContextState state) {
    overflowCalls++;
    state.pendingForceKeep = 2; // 模拟真实策略：置位强制收缩
  }
}

/// 脚本化 fake 交付段：记录 deliver / prime 入参，可脚本化溢出与异常。
class _FakeDelivery implements ChatDelivery {
  final List<({AssembledContext ctx, String systemPrompt})> delivered = [];
  final List<({AssembledContext ctx, String systemPrompt, bool nudgeTail})>
      primed = [];
  int stopCalls = 0;
  bool ready = true;

  /// 交付时抛出的异常（null = 正常）。抛 [LlmContextOverflowException] 即模拟
  /// 端侧 context full，抛别的即模拟普通失败。
  Object? throwOnDeliver;
  List<String> tokens = const [];

  @override
  bool get isReady => ready;

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
    primed.add((ctx: assembled, systemPrompt: systemPrompt, nudgeTail: nudgeTail));
  }

  @override
  void stop() => stopCalls++;

  @override
  void dispose() {}
}

void main() {
  late SettingsRepository settings;
  late _Recorder local;
  late _Recorder cloud;
  late LlmService service;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SettingsRepository.instance.initialize();
  });

  setUp(() async {
    settings = SettingsRepository.instance;
    await settings.setChatCloudMode(false);
    // 清空 BYOK 三件套（仓库是进程级单例，mock prefs 跨用例残留）。
    await settings.setCloudApiBaseUrl('');
    await settings.setCloudApiKey('');
    await settings.setCloudModelName('');
    local = _Recorder();
    cloud = _Recorder();
    service = LlmService(
      settings: settings,
      localAsk: local.ask,
      cloudAsk: cloud.ask,
    );
  });

  group('模式解析（唯一来源 + 入口复核）', () {
    test('本地模式：ask 委派 localAsk，不触达云端', () async {
      await service.ask(system: 's', user: 'u');

      expect(local.calls, hasLength(1));
      expect(cloud.calls, isEmpty);
      expect(local.calls.single.user, 'u');
    });

    test('云端模式（三件套齐）：ask 委派 cloudAsk', () async {
      await settings.setChatCloudMode(true);
      await settings.setCloudApiBaseUrl('https://api.example.com');
      await settings.setCloudApiKey('sk-test');
      await settings.setCloudModelName('test-model');

      await service.ask(system: 's', user: 'u');

      expect(cloud.calls, hasLength(1));
      expect(local.calls, isEmpty);
    });

    test('云端模式（三件套缺）：抛语义异常，不触达任何后端', () async {
      await settings.setChatCloudMode(true);
      // 不配置三件套（默认全空）

      await expectLater(
        service.ask(system: 's', user: 'u'),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('未配置'),
        )),
      );
      expect(local.calls, isEmpty);
      expect(cloud.calls, isEmpty);
    });

    test('模式每次调用时重新解析：中途切云端，下次调用即走云端（入口复核）',
        () async {
      await service.ask(system: 's', user: 'first');
      expect(local.calls, hasLength(1));

      await settings.setChatCloudMode(true);
      await settings.setCloudApiBaseUrl('https://api.example.com');
      await settings.setCloudApiKey('sk-test');
      await settings.setCloudModelName('test-model');

      await service.ask(system: 's', user: 'second');
      expect(cloud.calls, hasLength(1));
      expect(cloud.calls.single.user, 'second');
    });
  });

  group('askJson（解析容错唯一落点）', () {
    test('剥 markdown 围栏后解析成功，且 system 末尾带 JSON-only 约束', () async {
      local.reply = () => '```json\n{"relevant": true}\n```';

      final parsed = await service.askJson(system: 's', user: 'u');

      expect(parsed, {'relevant': true});
      expect(local.calls.single.system, startsWith('s'));
      expect(local.calls.single.system, contains('JSON'));
    });

    test('混杂说明文字时刮出首段 {...}', () async {
      local.reply = () => '好的，以下是结果：{"relevant": false} 请参考。';

      final parsed = await service.askJson(system: 's', user: 'u');

      expect(parsed, {'relevant': false});
    });

    test('think 包裹的 JSON：先剥 think 再解析', () async {
      local.reply = () =>
          '<think>推理过程 {干扰}</think>{"relevant": true, "new_goals": []}';

      final parsed = await service.askJson(system: 's', user: 'u');

      expect(parsed, isNotNull);
      expect(parsed!['relevant'], true);
    });

    test('无 JSON：返回 null（按无内容处理）', () async {
      local.reply = () => '这段对话是纯闲聊，没有可提取的内容。';

      final parsed = await service.askJson(system: 's', user: 'u');

      expect(parsed, isNull);
    });

    test('空回复：返回 null', () async {
      local.reply = () => '';

      expect(await service.askJson(system: 's', user: 'u'), isNull);
    });

    test('底层请求失败：异常透传（不吞成 null）', () async {
      local.throwOnCall = Exception('引擎加载失败');

      await expectLater(
        service.askJson(system: 's', user: 'u'),
        throwsA(isA<Exception>()),
      );
    });

    test('maxTokens 透传给后端', () async {
      local.reply = () => '{"ok": 1}';

      await service.askJson(system: 's', user: 'u', maxTokens: 777);

      expect(local.calls.single.maxTokens, 777);
    });
  });

  group('parseJsonReply（纯函数）', () {
    test('直解合法 JSON', () {
      expect(parseJsonReply('{"a": 1}'), {'a': 1});
    });

    test('围栏 + 尾随文字', () {
      expect(
        parseJsonReply('```json\n{"a": 1}\n```\n完毕'),
        {'a': 1},
      );
    });

    test('非对象 JSON 视为失败', () {
      expect(parseJsonReply('[1, 2, 3]'), isNull);
    });
  });

  group('converse（编排：转换 → 交付 → 溢出承接）', () {
    late _FakePolicy policy;
    late _FakeDelivery delivery;
    late ContextState state;

    ChatMessage user(String content) =>
        ChatMessage(role: MessageRole.user, content: content, round: 1);

    setUp(() {
      policy = _FakePolicy();
      delivery = _FakeDelivery();
      state = ContextState();
    });

    /// 注入接缝的服务 + 交付实例构造计数（验证「稳定实例」语义）。
    ({LlmService service, int Function() builtCount}) buildService() {
      var built = 0;
      final service = LlmService(
        settings: settings,
        policyFactory: () => policy,
        deliveryFactory: () {
          built++;
          return delivery;
        },
      );
      return (service: service, builtCount: () => built);
    }

    test('串联：先装配（拿到业务状态实例）再交付，人设原样透传', () async {
      final built = buildService();
      delivery.tokens = ['你', '好'];
      final history = [user('q')];

      final out = await built.service
          .converse(history, systemPrompt: '人设X', state: state)
          .toList();

      expect(out, ['你', '好']);
      expect(policy.assembleCalls.single, same(history)); // 业务列表原样进转换段
      expect(policy.overflowCalls, 0);
      expect(delivery.delivered.single.systemPrompt, '人设X');
      expect(delivery.primed, isEmpty);
    });

    test('交付实例稳定：连续两轮复用同一实例（端侧会话不复建）', () async {
      final built = buildService();
      delivery.tokens = ['回复'];

      await built.service
          .converse([user('a')], systemPrompt: 'S', state: state)
          .toList();
      await built.service
          .converse([user('a'), user('b')], systemPrompt: 'S', state: state)
          .toList();

      expect(delivery.delivered.length, 2);
      expect(built.builtCount(), 1); // 只建一次
    });

    test('端侧溢出：强制收缩 → 重新装配 → prime(nudgeTail:false) → 兜底文案',
        () async {
      final built = buildService();
      delivery.throwOnDeliver = const LlmContextOverflowException();
      // 首次装配给「全量」，自愈重装配给「收缩后」
      policy.build = (i) => AssembledContext(
            messages: [user(i == 0 ? '全量窗口' : '收缩后窗口')],
          );

      final out = await built.service
          .converse([user('q')], systemPrompt: 'S', state: state)
          .toList();

      expect(out, [kLlmFailureReply]); // 本轮以兜底文案收尾
      expect(policy.overflowCalls, 1); // 承接钩子被调用一次
      expect(state.pendingForceKeep, 2); // 状态实例被就地更新（业务持有）
      expect(policy.assembleCalls.length, 2); // 首次 + 自愈重装配
      expect(delivery.delivered.length, 1);
      expect(delivery.primed.length, 1);
      // 二次重放不再判定尾部去重（isDuplicate 有状态，本轮已判定过）
      expect(delivery.primed.single.nudgeTail, isFalse);
      expect(delivery.primed.single.ctx.messages.single.content, '收缩后窗口');
    });

    test('自愈重装配失败：吞掉并仍以兜底文案收尾（不二次抛错）', () async {
      final built = buildService();
      delivery.throwOnDeliver = const LlmContextOverflowException();
      policy.throwOnAssembleCallIndex = 1; // 自愈那一次装配抛错

      final out = await built.service
          .converse([user('q')], systemPrompt: 'S', state: state)
          .toList();

      expect(out, [kLlmFailureReply]);
      expect(delivery.primed, isEmpty);
    });

    test('非溢出异常原样上抛（超时等由业务决定降级）', () async {
      final built = buildService();
      delivery.throwOnDeliver = TimeoutException('帧间空闲');
      delivery.tokens = ['半截'];

      await expectLater(
        built.service.converse([user('q')], systemPrompt: 'S', state: state),
        emitsError(isA<TimeoutException>()),
      );
    });

    test('stop 转发到当前交付实例（含测试接缝实例）', () async {
      final built = buildService();
      await built.service
          .converse([user('q')], systemPrompt: 'S', state: state)
          .toList();

      built.service.stop();

      expect(delivery.stopCalls, 1);
    });
  });
}
