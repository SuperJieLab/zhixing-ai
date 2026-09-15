import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/data/models/available_model.dart';

/// 模型就绪状态管理（core 层）
///
/// 只负责回答一个问题：本地是否有可用模型？
/// 不涉及下载、进度、速度等 UI 相关的下载管理逻辑。
///
/// **非单例**：由 composition root（main）构造一次，UI 侧经 Provider 树
/// `context.watch<ActiveModelManager>()` 消费；需要"当前活跃模型"的 core 服务
/// （`LlmService`）经构造注入拿到同一个实例的 [activeModelPath] 源。
/// 这样实例可被测试直接替换，无需全局开关或手动复位。
class ActiveModelManager extends ChangeNotifier {
  ActiveModelManager();

  String? _activeModelId;

  /// 已下载到本地的模型 ID 集合（所有，不只是当前活跃的）
  final Set<String> _downloadedModelIds = {};

  /// 当前活跃模型的文件路径；null = 尚无可用模型。
  ///
  /// 形态同 `LlmService.mode`：**状态源以 ValueListenable 注入消费方**，
  /// 而非放在全局常量里。`LlmService` 监听它就能知道「换成了哪个模型」，
  /// 并据此拆除旧引擎池条目；同值重复通知不会触发重建。
  final ValueNotifier<String?> _activeModelPath = ValueNotifier<String?>(null);

  ValueListenable<String?> get activeModelPath => _activeModelPath;

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
  /// 在 composition root 中调用（异步，不 await）。
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
      _activeModelPath.value = await savePath(model);
    } else if (_downloadedModelIds.isNotEmpty) {
      // 回退：第一个可用的模型
      final fallbackId = AvailableModel.available
          .firstWhere((m) => _downloadedModelIds.contains(m.id))
          .id;
      _activeModelId = fallbackId;
      final model = AvailableModel.available.firstWhere((m) => m.id == fallbackId);
      _activeModelPath.value = await savePath(model);
    }

    notifyListeners();
  }

  /// 下载完成后由 [ModelDownloadProvider] 调用，设置模型就绪
  void setModelReady(String modelId, String savePath) {
    _downloadedModelIds.add(modelId);
    _activeModelId = modelId;
    _activeModelPath.value = savePath;
    _savePreference(modelId);
    notifyListeners();
  }

  /// 切换到指定的已下载模型
  void switchToModel(String modelId) async {
    if (!_downloadedModelIds.contains(modelId)) return;
    _activeModelId = modelId;
    final model = AvailableModel.available.firstWhere((m) => m.id == modelId);
    _activeModelPath.value = await savePath(model);
    _savePreference(modelId);
    notifyListeners();
  }

  @override
  void dispose() {
    _activeModelPath.dispose();
    super.dispose();
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
    }).catchError((Object _) {
      // 沙盒路径不可用时（如测试环境）忽略：偏好只是加速恢复，非必需
    });
  }
}
