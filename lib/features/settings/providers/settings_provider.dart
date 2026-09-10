import 'package:flutter/foundation.dart';

import 'package:zhixing_ai/core/data/repository/settings_repository.dart';

/// 设置页状态（feature 层）
///
/// 包装 [SettingsRepository]，为设置页提供可响应的开关状态。
/// 不使用全局 Provider 注入——由 [SettingsPage] 内部自行管理，
/// 通过 [ChangeNotifierProvider] 在页面 widget tree 内注入。
class SettingsProvider extends ChangeNotifier {
  final SettingsRepository _repo;

  SettingsProvider({SettingsRepository? repo})
      : _repo = repo ?? SettingsRepository.instance;

  bool get useGpuAcceleration => _repo.useGpuAcceleration;

  /// 切换 GPU 加速。修改持久化后下次加载模型引擎即生效
  /// （已加载的引擎沿用旧配置，直到下一次加载）。
  Future<void> setUseGpuAcceleration(bool value) async {
    if (_repo.useGpuAcceleration == value) return;
    await _repo.setUseGpuAcceleration(value);
    notifyListeners();
  }

  bool get useAiOptimizedPush => _repo.useAiOptimizedPush;

  /// 切换「AI 优化推送」。持久化后下次同步即生效。
  Future<void> setUseAiOptimizedPush(bool value) async {
    if (_repo.useAiOptimizedPush == value) return;
    await _repo.setUseAiOptimizedPush(value);
    notifyListeners();
  }

  /// 是否已同意隐私说明（首次开启弹窗用）。
  bool get aiPushConsented => _repo.aiPushConsented;

  Future<void> setAiPushConsented(bool value) async {
    if (_repo.aiPushConsented == value) return;
    await _repo.setAiPushConsented(value);
    notifyListeners();
  }

  bool get chatCloudMode => _repo.chatCloudMode;

  /// 切换「云端对话模式」。持久化后下次新对话生效。
  /// 隐私同意判定在设置页（[SettingsPage]）处理，此处只负责持久化。
  Future<void> setChatCloudMode(bool value) async {
    if (_repo.chatCloudMode == value) return;
    await _repo.setChatCloudMode(value);
    notifyListeners();
  }

  /// 是否已同意云端对话的隐私说明（首次开启弹窗用）。
  bool get chatCloudConsented => _repo.chatCloudConsented;

  Future<void> setChatCloudConsented(bool value) async {
    if (_repo.chatCloudConsented == value) return;
    await _repo.setChatCloudConsented(value);
    notifyListeners();
  }

  // ─── 云端 BYOK 直连配置 ───

  String get cloudApiBaseUrl => _repo.cloudApiBaseUrl;

  Future<void> setCloudApiBaseUrl(String value) async {
    if (_repo.cloudApiBaseUrl == value) return;
    await _repo.setCloudApiBaseUrl(value);
    notifyListeners();
  }

  String get cloudApiKey => _repo.cloudApiKey;

  Future<void> setCloudApiKey(String value) async {
    if (_repo.cloudApiKey == value) return;
    await _repo.setCloudApiKey(value);
    notifyListeners();
  }

  String get cloudModelName => _repo.cloudModelName;

  Future<void> setCloudModelName(String value) async {
    if (_repo.cloudModelName == value) return;
    await _repo.setCloudModelName(value);
    notifyListeners();
  }

  /// 三件套齐全才允许开启云端模式（设置页门禁用）。
  bool get isCloudApiConfigured => _repo.isCloudApiConfigured;
}
