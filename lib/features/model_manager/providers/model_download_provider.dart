import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:zhixing_ai/core/llm/active_model_manager.dart';
import 'package:zhixing_ai/core/data/models/available_model.dart';
import 'package:zhixing_ai/features/model_manager/engine/model_download_service.dart';

enum DownloadStatus { idle, downloading, completed, failed, cancelled }

/// 单个模型的下载状态快照
class ModelDownloadState {
  final DownloadStatus status;
  final double progress;
  final int receivedBytes;
  final int totalBytes;
  final String speedText;
  final String etaText;
  final String? error;

  const ModelDownloadState({
    this.status = DownloadStatus.idle,
    this.progress = 0.0,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.speedText = '',
    this.etaText = '',
    this.error,
  });
}

/// 模型下载状态管理（feature 层）
///
/// 管理下载生命周期：下载 → 进度 → 完成/失败/取消。
/// 下载完成后通过 [ActiveModelManager.setModelReady] 通知 core 层。
///
/// 不使用 Provider 全局注入——由 [ModelManagePage] 内部自行管理，
/// 通过 [ChangeNotifierProvider] 在页面 widget tree 内注入。
class ModelDownloadProvider extends ChangeNotifier {
  final ModelDownloadService _service;

  ModelDownloadProvider({ModelDownloadService? service})
      : _service = service ?? ModelDownloadService() {
    _initStates();
  }

  final Map<String, ModelDownloadState> _states = {};

  /// 从 ActiveModelManager 同步已下载模型的状态，避免已下载的模型显示"下载"按钮
  void _initStates() {
    final manager = ActiveModelManager.instance;
    for (final model in AvailableModel.available) {
      if (manager.isDownloaded(model.id)) {
        _states[model.id] = const ModelDownloadState(
          status: DownloadStatus.completed,
          progress: 1.0,
        );
      }
    }
  }

  Timer? _speedTimer;
  int _lastReceived = 0;
  DateTime _lastCheckTime = DateTime.now();

  ModelDownloadState stateOf(String modelId) =>
      _states[modelId] ?? const ModelDownloadState();

  Future<void> startDownload(AvailableModel model) async {
    final savePath = await ActiveModelManager.instance.savePath(model);

    _states[model.id] = const ModelDownloadState(status: DownloadStatus.downloading);
    notifyListeners();

    _speedTimer?.cancel();
    _speedTimer = Timer.periodic(const Duration(seconds: 1), (_) => _updateSpeed(model.id));

    try {
      final success = await _downloadWithFallback(model, savePath);

      _speedTimer?.cancel();

      if (success) {
        _states[model.id] = ModelDownloadState(
          status: DownloadStatus.completed,
          progress: 1.0,
          receivedBytes: model.sizeBytes,
          totalBytes: model.sizeBytes,
        );
        // 通知 core 层：模型就绪
        ActiveModelManager.instance.setModelReady(model.id, savePath);
      } else {
        _states[model.id] = const ModelDownloadState(status: DownloadStatus.cancelled);
      }
      notifyListeners();
    } catch (e) {
      _speedTimer?.cancel();
      _states[model.id] = ModelDownloadState(
        status: DownloadStatus.failed,
        error: e.toString(),
        receivedBytes: _states[model.id]?.receivedBytes ?? 0,
        totalBytes: _states[model.id]?.totalBytes ?? model.sizeBytes,
      );
      notifyListeners();
    }
  }

  Future<bool> _downloadWithFallback(AvailableModel model, String savePath) async {
    return _service.download(
      url: model.mirrorUrl,
      savePath: savePath,
      onProgress: ({required received, required total}) {
        final effectiveTotal = total > 0 ? total : model.sizeBytes;
        _states[model.id] = ModelDownloadState(
          status: DownloadStatus.downloading,
          progress: effectiveTotal > 0 ? received / effectiveTotal : 0,
          receivedBytes: received,
          totalBytes: effectiveTotal,
          speedText: _states[model.id]?.speedText ?? '',
          etaText: _states[model.id]?.etaText ?? '',
        );
        notifyListeners();
      },
    );
  }

  void _updateSpeed(String modelId) {
    final state = _states[modelId];
    if (state == null || state.status != DownloadStatus.downloading) return;

    final now = DateTime.now();
    final elapsed = now.difference(_lastCheckTime).inMilliseconds / 1000.0;
    if (elapsed <= 0) return;

    final delta = state.receivedBytes - _lastReceived;
    final speedBytes = delta / elapsed;

    final remaining = state.totalBytes - state.receivedBytes;
    final etaSeconds = speedBytes > 0 && remaining > 0
        ? (remaining / speedBytes).round()
        : 0;

    _states[modelId] = ModelDownloadState(
      status: state.status,
      progress: state.progress,
      receivedBytes: state.receivedBytes,
      totalBytes: state.totalBytes,
      speedText: formatSpeed(speedBytes),
      etaText: etaSeconds > 0 ? formatEta(etaSeconds) : '',
    );
    _lastReceived = state.receivedBytes;
    _lastCheckTime = now;
    notifyListeners();
  }

  void cancelDownload(String modelId) {
    _service.cancel();
    _speedTimer?.cancel();
    _states.remove(modelId);
    notifyListeners();
  }

  @override
  void dispose() {
    _speedTimer?.cancel();
    super.dispose();
  }

  // ─── 格式化工具（public 以便测试和 UI 复用） ───

  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond < 1024) return '${bytesPerSecond.toInt()} B/s';
    if (bytesPerSecond < 1024 * 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  static String formatEta(int seconds) {
    if (seconds < 60) return '剩余 $seconds 秒';
    if (seconds < 3600) return '剩余 ${seconds ~/ 60} 分钟';
    return '剩余 ${seconds ~/ 3600} 小时';
  }
}
