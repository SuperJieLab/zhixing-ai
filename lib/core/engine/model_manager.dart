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

  /// 是否有可用模型
  bool get hasModel => _activeModelId != null;

  /// 当前活跃模型的 ID
  String? get activeModelId => _activeModelId;

  /// 模型文件在沙盒中的保存路径
  Future<String> savePath(AvailableModel model) async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/${AppConstants.modelSubDir}/${model.fileName}';
  }

  /// 扫描本地已下载的模型，设置就绪状态
  ///
  /// 在 main() 的 Provider create 中调用（异步，不 await）。
  /// 完成后 notifyListeners() → 依赖方自动重建。
  Future<void> checkLocalModels() async {
    for (final model in AvailableModel.available) {
      final path = await savePath(model);
      final file = File(path);
      if (await file.exists() && await file.length() >= model.sizeBytes * 0.99) {
        _activeModelId = model.id;
        AppConstants.defaultModelPath = path;
      }
    }
    notifyListeners();
  }

  /// 下载完成后由 [ModelDownloadProvider] 调用，设置模型就绪
  void setModelReady(String modelId, String savePath) {
    _activeModelId = modelId;
    AppConstants.defaultModelPath = savePath;
    notifyListeners();
  }
}
