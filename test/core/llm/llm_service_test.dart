import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhixing_ai/core/data/repository/settings_repository.dart';
import 'package:zhixing_ai/core/llm/generation/generation.dart';
import 'package:zhixing_ai/core/context/context_assembly.dart';
import 'package:zhixing_ai/core/llm/llm.dart';
import 'package:zhixing_ai/core/llm/llm_service.dart';

/// 记录调用的 fake 后端接缝（[SingleShotAsk] 形态）。
class _Recorder {  final List<({String system, String user, int? maxTokens})> calls = [];
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


/// 记录释放次数的交付 fake（生命周期测试用：验证延迟释放 / 防抖）。
class _RecordingDelivery implements ChatGeneration {
  int disposed = 0;

  @override
  bool get isReady => true;

  @override
  Future<void> ensureReady() async {}

  @override
  Stream<String> deliver(
    AssembledContext assembled, {
    required String systemPrompt,
    bool nudgeTail = true,
  }) async* {}

  @override
  void prime(
    AssembledContext assembled, {
    required String systemPrompt,
    bool nudgeTail = true,
  }) {}

  @override
  void stop() {}

  @override
  void dispose() => disposed++;
}

/// 可从测试触发的模型变更通知源（真实 ActiveModelManager 无法外部 notify）。
void main() {
  late SettingsRepository settings;
  late _Recorder local;
  late _Recorder cloud;
  late LlmService service;

  /// 活跃模型路径源（生产注入 `ActiveModelManager.activeModelPath`）。
  /// 直接改 value 即模拟「下载完成 / 切换模型」——ValueNotifier 自动通知，
  /// 同值赋值不通知（覆盖「重复通知」场景）；无需全局常量与手动开关。
  late ValueNotifier<String?> modelPath;

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
    modelPath = ValueNotifier<String?>(null);
    addTearDown(modelPath.dispose);
    service = LlmService(
      settings: settings,
      activeModelPath: modelPath,
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

    test('非对象 JSON（数组）→ 返回 null', () async {
      local.reply = () => '[1, 2, 3]';

      expect(await service.askJson(system: 's', user: 'u'), isNull);
    });
  });

  group('生命周期（窄通知 + 冷启动预热 + 延迟释放防抖）', () {
    /// 构建注入本地交付接缝的服务；返回构建出的交付列表供断言。
    ({LlmService service, List<_RecordingDelivery> built}) buildLifecycle({
      Duration delayedRelease = const Duration(seconds: 30),
    }) {
      final built = <_RecordingDelivery>[];
      final service = LlmService(
        settings: settings,
        activeModelPath: modelPath,
        localDeliveryBuilder: () async {
          final d = _RecordingDelivery();
          built.add(d);
          return d;
        },
        delayedRelease: delayedRelease,
      );
      addTearDown(service.dispose);
      return (service: service, built: built);
    }

    Future<void> configureCloud() async {
      await settings.setCloudApiBaseUrl('https://api.example.com');
      await settings.setCloudApiKey('sk-test');
      await settings.setCloudModelName('test-model');
      await settings.setChatCloudMode(true);
    }

    test('本地模式冷启动：initialize 异步预热 → ready，构建一次', () async {
      final built = buildLifecycle();

      await built.service.initialize();

      expect(built.built, hasLength(1));
      expect(built.service.readiness.value.phase, LlmPhase.ready);
      expect(built.service.isReady, isTrue);
    });

    test('云端未配齐：initialize → failed（带语义错误），不触碰本地资源', () async {
      await settings.setChatCloudMode(true); // 三件套为空
      final built = buildLifecycle();

      await built.service.initialize();

      expect(built.built, isEmpty);
      expect(built.service.readiness.value.phase, LlmPhase.failed);
      expect(built.service.readiness.value.error, isA<StateError>());
      expect(built.service.isReady, isFalse);
    });

    test('云端配齐：initialize → ready（云端就绪化瞬时），不构建本地交付',
        () async {
      await configureCloud();
      final built = buildLifecycle();

      await built.service.initialize();

      expect(built.built, isEmpty);
      expect(built.service.readiness.value.phase, LlmPhase.ready);
    });

    test('ensureReady：本地失败 → failed 并抛出；修复后可重试成功', () async {
      var shouldFail = true;
      final service = LlmService(
        settings: settings,
        activeModelPath: modelPath,
        localDeliveryBuilder: () async {
          if (shouldFail) throw StateError('模型缺失');
          return _RecordingDelivery();
        },
      );
      addTearDown(service.dispose);

      await expectLater(service.ensureReady(), throwsA(isA<StateError>()));
      expect(service.readiness.value.phase, LlmPhase.failed);

      shouldFail = false;
      await service.ensureReady(); // 失败不缓存，允许重试
      expect(service.readiness.value.phase, LlmPhase.ready);
    });

    /// 真实短定时器版延迟释放验证。
    ///
    /// 不用 fakeAsync：SharedPreferences mock 的写入 Future 在 fakeAsync
    /// zone 内不完成（探针证实），通知根本不会触发。改用可注入的短窗口
    /// （150ms）+ 真实等待，裕量 ≥ 50ms，避免 CI 抖动。
    const releaseWindow = Duration(milliseconds: 150);

    Future<void> pump(int ms) =>
        Future<void>.delayed(Duration(milliseconds: ms));

    test('切云端：本地资源延迟到点释放一次', () async {
      final built =
          buildLifecycle(delayedRelease: releaseWindow);
      await built.service.initialize();

      await configureCloud();
      expect(built.built.single.disposed, 0); // 未到点不释放
      expect(built.service.readiness.value.phase, LlmPhase.ready);

      await pump(releaseWindow.inMilliseconds + 100);
      expect(built.built.single.disposed, 1); // 到点恰好释放一次
    });

    test('防抖：切回本地取消释放；再切云端重新计时', () async {
      final built =
          buildLifecycle(delayedRelease: releaseWindow);
      await built.service.initialize();

      await settings.setChatCloudMode(true);
      await pump(80); // 窗口内
      expect(built.built.single.disposed, 0);

      await settings.setChatCloudMode(false); // 切回本地：取消释放
      await settings.setChatCloudMode(true); // 再切云端：重新计时
      await pump(100); // 距重排 100 < 150
      expect(built.built.single.disposed, 0); // 计时被重置，未释放

      await pump(100); // 累计 200 ≥ 150
      expect(built.built.single.disposed, 1);
      expect(built.built, hasLength(1)); // 全程未重建（切回时实例仍在）
    });

    test('释放后切回本地：重新构建本地交付并回到 ready', () async {
      final built =
          buildLifecycle(delayedRelease: releaseWindow);
      await built.service.initialize();

      await settings.setChatCloudMode(true);
      await pump(releaseWindow.inMilliseconds + 100);
      expect(built.built.single.disposed, 1);

      await settings.setChatCloudMode(false);
      await pump(50);
      expect(built.built, hasLength(2)); // 重建
      expect(built.service.readiness.value.phase, LlmPhase.ready);
    });

    test('BYOK 指纹变更：旧云端交付即刻废弃，防抖计时重排', () async {
      final built =
          buildLifecycle(delayedRelease: releaseWindow);
      await built.service.initialize();

      await configureCloud();
      await pump(100); // 窗口内
      expect(built.built.single.disposed, 0);

      await settings.setCloudApiKey('sk-new'); // 指纹变化 → 重排计时
      await pump(90); // 距重排 90 < 150
      expect(built.built.single.disposed, 0);

      await pump(80); // 累计 170 ≥ 150
      expect(built.built.single.disposed, 1);
    });

    test('构建在途切云端：构建完成后弃置（dispose 一次）、不缓存、就绪态不被覆盖',
        () async {
      // 冷启动预热挂起在引擎加载中途（真实场景：模型加载 ~15s，用户等不及切云端）
      final gates = <Completer<ChatGeneration>>[Completer(), Completer()];
      var call = 0;
      final service = LlmService(
        settings: settings,
        activeModelPath: modelPath,
        localDeliveryBuilder: () => gates[call++].future,
        delayedRelease: releaseWindow,
      );
      addTearDown(service.dispose);

      final init = service.initialize(); // 预热 → 构建挂起
      await Future<void>.delayed(Duration.zero);
      expect(call, 1);

      await configureCloud(); // 构建在途切云端 → 释放计时排上，就绪态 ready
      expect(service.readiness.value.phase, LlmPhase.ready);

      // 构建完成时已是云端模式：交付必须弃置（不缓存成泄漏），且本地构建
      // 的「失败」不得把云端 ready 覆盖成 failed
      final orphan = _RecordingDelivery();
      gates[0].complete(orphan);
      await init; // initialize 内部吞错

      expect(orphan.disposed, 1);
      expect(service.readiness.value.phase, LlmPhase.ready);

      // 延迟释放到点（teardown 走池失效）；随后切回本地 → 重新构建而非复用脏缓存
      await pump(releaseWindow.inMilliseconds + 100);
      await settings.setChatCloudMode(false);
      await pump(20);
      expect(call, 2); // 重新构建

      final rebuilt = _RecordingDelivery();
      gates[1].complete(rebuilt);
      await pump(10);
      expect(service.readiness.value.phase, LlmPhase.ready);
    });
  });

  group('活跃模型切换（旧引擎资源立即拆除）', () {
    Future<void> pump(int ms) =>
        Future<void>.delayed(Duration(milliseconds: ms));

    test('本地模式切模型：旧交付 dispose、按新模型重建、回到 ready', () async {
      modelPath.value = '/tmp/model-a.gguf';

      final built = <_RecordingDelivery>[];
      final service = LlmService(
        settings: settings,
        activeModelPath: modelPath,
        localDeliveryBuilder: () async {
          final d = _RecordingDelivery();
          built.add(d);
          return d;
        },
      );
      addTearDown(service.dispose);

      await service.initialize();
      expect(built, hasLength(1));
      expect(service.readiness.value.phase, LlmPhase.ready);

      // 切换模型：改路径即通知（ActiveModelManager.switchToModel 的语义）
      modelPath.value = '/tmp/model-b.gguf';
      await pump(20);

      expect(built.first.disposed, 1); // 旧交付（旧模型会话）立即拆除
      expect(built, hasLength(2)); // 为新模型重建
      expect(service.readiness.value.phase, LlmPhase.ready);
    });

    test('同路径重复赋值（如下载完成的重复通知）：不通知、不拆除不重建', () async {
      modelPath.value = '/tmp/model-a.gguf';

      final built = <_RecordingDelivery>[];
      final service = LlmService(
        settings: settings,
        activeModelPath: modelPath,
        localDeliveryBuilder: () async {
          final d = _RecordingDelivery();
          built.add(d);
          return d;
        },
      );
      addTearDown(service.dispose);

      await service.initialize();
      expect(built, hasLength(1));

      modelPath.value = '/tmp/model-a.gguf'; // 同值 → ValueNotifier 不通知
      await pump(20);

      expect(built, hasLength(1));
      expect(built.single.disposed, 0);
    });
  });

  group('模式源（D2：供 ModelGateway 注入）', () {
    test('构造时按当前设置初始化', () {
      expect(service.mode.value, ChatMode.local);
    });

    test('切换模式 → notifier 同步更新；BYOK 变更不误触发', () async {
      // initialize 注册 backendListenable 监听（生产路径必经），通知提前同步。
      unawaited(service.initialize().catchError((Object _) {}));
      final changes = <ChatMode>[];
      service.mode.addListener(() => changes.add(service.mode.value));

      await settings.setChatCloudMode(true);
      await settings.setCloudApiBaseUrl('https://api.example.com');
      expect(service.mode.value, ChatMode.cloud);

      await settings.setChatCloudMode(false);
      expect(service.mode.value, ChatMode.local);

      // 本地→本地（BYOK 变更触发通知但模式未变）：不产生变更事件
      expect(changes, [ChatMode.cloud, ChatMode.local]);
    });
  });
}
