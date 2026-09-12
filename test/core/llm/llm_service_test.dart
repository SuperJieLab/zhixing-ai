import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhixing_ai/core/data/repository/settings_repository.dart';
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
}
