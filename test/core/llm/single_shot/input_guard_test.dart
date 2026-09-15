import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhixing_ai/core/llm/single_shot/input_guard.dart';
import 'package:zhixing_ai/core/llm/llm.dart';
import 'package:zhixing_ai/core/llm/llm_service.dart';
import 'package:zhixing_ai/core/data/repository/settings_repository.dart';
import 'package:zhixing_ai/core/constants.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SettingsRepository.instance.initialize();
  });

  group('ensureInputWithinBudget（纯函数）', () {
    test('本地模式：输入远小于预算，不抛', () {
      expect(
        () => ensureInputWithinBudget(
            mode: ChatMode.local, system: '系统提示', user: '用户问题'),
        returnsNormally,
      );
    });

    test('本地模式：超 localInputBudget（token 口径）抛类型化异常', () {
      // 端侧预算 1668 token；构造远超的输入（数万字符必然超）。
      final huge = '长' * 5000;
      try {
        ensureInputWithinBudget(
            mode: ChatMode.local, system: 's', user: huge);
        fail('应当抛 GatewayInputOverflowException');
      } on GatewayInputOverflowException catch (e) {
        expect(e.mode, ChatMode.local);
        expect(e.budget, AppConstants.localInputBudget);
        expect(e.measured, greaterThan(AppConstants.localInputBudget));
      }
    });

    test('云端模式：超 cloudInputBudget（字符口径，含每条包装开销）抛异常', () {
      // 60000 字符预算 − 2×16 包装开销 → 边界内最大输入应为 59968 字符；
      // 60000 字符本体已超（60000 + 32 > 60000）。
      final over = 'a' * AppConstants.cloudInputBudget;
      expect(
        () => ensureInputWithinBudget(
            mode: ChatMode.cloud, system: 's', user: over),
        throwsA(isA<GatewayInputOverflowException>()),
      );
    });

    test('云端模式：预算边界内（60000 − 2×16 − system 长度 字符）不抛', () {
      final within =
          'a' * (AppConstants.cloudInputBudget - 2 * 16 - 1); // system 's' 占 1 字符
      expect(
        () => ensureInputWithinBudget(
            mode: ChatMode.cloud, system: 's', user: within),
        returnsNormally,
      );
    });
  });

  group('LlmService.ask / askJson 端到端守门（fail-fast）', () {
    late SettingsRepository settings;
    late _NoCallRecorder backend;

    /// 守门测试不触达引擎，模型路径源只需满足注入契约。
    late ValueNotifier<String?> modelPath;

    setUp(() async {
      settings = SettingsRepository.instance;
      await settings.setChatCloudMode(false);
      backend = _NoCallRecorder();
      modelPath = ValueNotifier<String?>(null);
      addTearDown(modelPath.dispose);
    });

    test('本地模式：ask 超预算抛异常，后端接缝零触达', () async {
      final service = LlmService(
          settings: settings, activeModelPath: modelPath, localAsk: backend.ask);
      await expectLater(
        service.ask(system: 's', user: '长' * 5000),
        throwsA(isA<GatewayInputOverflowException>()),
      );
      expect(backend.calls, isEmpty); // fail-fast：不发生引擎动作
    });

    test('本地模式：askJson 经 ask 透传同样被守门', () async {
      final service = LlmService(
          settings: settings, activeModelPath: modelPath, localAsk: backend.ask);
      await expectLater(
        service.askJson(system: 's', user: '长' * 5000),
        throwsA(isA<GatewayInputOverflowException>()),
      );
      expect(backend.calls, isEmpty);
    });

    test('云端模式：超字符预算抛异常，BYOK 请求零触达', () async {
      await settings.setChatCloudMode(true);
      await settings.setCloudApiBaseUrl('https://api.example.com');
      await settings.setCloudApiKey('sk-test');
      await settings.setCloudModelName('test-model');
      final service = LlmService(
          settings: settings, activeModelPath: modelPath, cloudAsk: backend.ask);

      await expectLater(
        service.ask(system: 's', user: 'a' * AppConstants.cloudInputBudget),
        throwsA(isA<GatewayInputOverflowException>()),
      );
      expect(backend.calls, isEmpty);
    });

    test('正常小输入不受影响：守门放行，后端正常调用', () async {
      final service = LlmService(
          settings: settings, activeModelPath: modelPath, localAsk: backend.ask);
      final out = await service.ask(system: 's', user: 'u');
      expect(out, 'ok');
      expect(backend.calls, hasLength(1));
    });
  });
}

/// 守门测试专用接缝：只记录调用、绝不真正执行。
class _NoCallRecorder {
  final List<({String system, String user, int? maxTokens})> calls = [];

  Future<String> ask({
    required String system,
    required String user,
    int? maxTokens,
  }) async {
    calls.add((system: system, user: user, maxTokens: maxTokens));
    return 'ok';
  }
}
