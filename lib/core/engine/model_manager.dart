import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:socratic_ai/core/constants.dart';
import 'package:socratic_ai/core/models/available_model.dart';

/// 模型就绪状态管理（core 层）
///
/// 只负责回答一个问题：本地是否有可用模型？
/// 不涉及下载、进度、速度等 UI 相关的下载管理逻辑。
///
/// 在 main() 的 MultiProvider 中全局注入，
/// TopicSelectionPage、ChatPage 等通过 watch 消费就绪状态。
class ModelManager extends ChangeNotifier {
  static final ModelManager instance = ModelManager._();

  ModelManager._();

  String? _activeModelId;

  /// 已下载到本地的模型 ID 集合（所有，不只是当前活跃的）
  final Set<String> _downloadedModelIds = {};

  /// 是否有可用模型
  bool get hasModel => _activeModelId != null;

  /// 当前活跃模型的 ID
  String? get activeModelId => _activeModelId;

  /// 指定模型是否已下载到本地
  bool isDownloaded(String modelId) => _downloadedModelIds.contains(modelId);

  /// 模型文件在沙盒中的保存路径
  Future<String> savePath(AvailableModel model) async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/${AppConstants.modelSubDir}/${model.fileName}';
  }

  /// 扫描本地已下载的模型，设置就绪状态
  ///
  /// 优先加载上次用户选择的模型；如果该模型不在本地，
  /// 则回退到第一个可用的已下载模型。
  ///
  /// 在 main() 的 Provider create 中调用（异步，不 await）。
  /// 完成后 notifyListeners() → 依赖方自动重建。
  Future<void> checkLocalModels() async {
    // 读取上次选择
    final preferred = await _loadPreference();

    for (final model in AvailableModel.available) {
      final path = await savePath(model);
      final file = File(path);
      if (await file.exists() && await file.length() >= model.sizeBytes * 0.95) {
        _downloadedModelIds.add(model.id);
      }
    }

    // 优先恢复上次选择的模型
    if (preferred != null && _downloadedModelIds.contains(preferred)) {
      _activeModelId = preferred;
      final model = AvailableModel.available.firstWhere((m) => m.id == preferred);
      AppConstants.defaultModelPath = await savePath(model);
    } else if (_downloadedModelIds.isNotEmpty) {
      // 回退：第一个可用的模型
      final fallbackId = AvailableModel.available
          .firstWhere((m) => _downloadedModelIds.contains(m.id))
          .id;
      _activeModelId = fallbackId;
      final model = AvailableModel.available.firstWhere((m) => m.id == fallbackId);
      AppConstants.defaultModelPath = await savePath(model);
    }

    notifyListeners();
  }

  /// 下载完成后由 [ModelDownloadProvider] 调用，设置模型就绪
  void setModelReady(String modelId, String savePath) {
    _downloadedModelIds.add(modelId);
    _activeModelId = modelId;
    AppConstants.defaultModelPath = savePath;
    _savePreference(modelId);
    notifyListeners();
  }

  /// 切换到指定的已下载模型
  void switchToModel(String modelId) async {
    if (!_downloadedModelIds.contains(modelId)) return;
    _activeModelId = modelId;
    final model = AvailableModel.available.firstWhere((m) => m.id == modelId);
    AppConstants.defaultModelPath = await savePath(model);
    _savePreference(modelId);
    notifyListeners();
  }

  // ================================================================
  // 偏好持久化
  // ================================================================

  Future<String> _prefsFilePath() async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/model_preference.json';
  }

  Future<String?> _loadPreference() async {
    try {
      final file = File(await _prefsFilePath());
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return json['activeModelId'] as String?;
    } catch (_) {
      return null;
    }
  }

  void _savePreference(String modelId) {
    final prefs = {'activeModelId': modelId};
    _prefsFilePath().then((path) async {
      try {
        await File(path).writeAsString(jsonEncode(prefs));
      } catch (_) {
        // 偏好写入失败不影响核心功能，下次启动回退到第一个可用模型
      }
    });
  }
}
