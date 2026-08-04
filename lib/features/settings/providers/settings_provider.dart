import 'package:flutter/foundation.dart';

import 'package:zhixing_ai/core/repository/settings_repository.dart';

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
}
