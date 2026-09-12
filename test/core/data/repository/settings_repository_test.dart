import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhixing_ai/core/data/repository/settings_repository.dart';

/// SettingsRepository 云端 BYOK 配置单测（SharedPreferences mock）。
/// 既有开关（GPU/AI 推送/云端模式）由使用方测试覆盖，此处只测新增三件套。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsRepository repo;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    repo = SettingsRepository.instance;
    await repo.initialize(); // late final _prefs 只能赋值一次，全局初始化一次
  });

  setUp(() async {
    // 用 setter 清空（空串与未存对 getter 等价），保证用例间隔离。
    await repo.setCloudApiBaseUrl('');
    await repo.setCloudApiKey('');
    await repo.setCloudModelName('');
  });

  group('云端 BYOK 配置', () {
    test('默认三项均为空字符串', () {
      expect(repo.cloudApiBaseUrl, '');
      expect(repo.cloudApiKey, '');
      expect(repo.cloudModelName, '');
      expect(repo.isCloudApiConfigured, isFalse);
    });

    test('setter 持久化并 trim 首尾空白', () async {
      await repo.setCloudApiBaseUrl('  https://api.deepseek.com  ');
      await repo.setCloudApiKey(' sk-test ');
      await repo.setCloudModelName(' deepseek-chat ');

      expect(repo.cloudApiBaseUrl, 'https://api.deepseek.com');
      expect(repo.cloudApiKey, 'sk-test');
      expect(repo.cloudModelName, 'deepseek-chat');
      expect(repo.isCloudApiConfigured, isTrue);
    });

    test('三缺一即视为未配置', () async {
      await repo.setCloudApiBaseUrl('https://api.deepseek.com');
      await repo.setCloudApiKey('sk-test');
      expect(repo.isCloudApiConfigured, isFalse);

      await repo.setCloudModelName('deepseek-chat');
      expect(repo.isCloudApiConfigured, isTrue);

      await repo.setCloudApiKey('   '); // 清空其一 → 又不齐
      expect(repo.isCloudApiConfigured, isFalse);
    });

    test('纯空白输入不构成「已配置」', () async {
      await repo.setCloudApiBaseUrl('   ');
      await repo.setCloudApiKey('sk-test');
      await repo.setCloudModelName('deepseek-chat');
      expect(repo.isCloudApiConfigured, isFalse);
    });
  });

  group('后端窄通知源（backendListenable）', () {
    int notified = 0;
    late VoidCallback listener;

    setUp(() {
      notified = 0;
      listener = () => notified++;
      repo.backendListenable.addListener(listener);
    });

    tearDown(() {
      repo.backendListenable.removeListener(listener);
    });

    test('影响后端的写入触发通知：模式开关 + BYOK 三件套', () async {
      await repo.setChatCloudMode(true);
      expect(notified, 1);

      await repo.setCloudApiBaseUrl('https://api.example.com');
      await repo.setCloudApiKey('sk-test');
      await repo.setCloudModelName('test-model');
      expect(notified, 4);
    });

    test('其余设置项不通知（窄语义：只服务后端切换）', () async {
      await repo.setUseGpuAcceleration(true);
      await repo.setUseAiOptimizedPush(true);
      await repo.setAiPushConsented(true);
      await repo.setChatCloudConsented(true);

      expect(notified, 0);
    });
  });
}
