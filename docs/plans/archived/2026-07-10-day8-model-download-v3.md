# Day 8 — 模型下载与管理 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在 TopicsPage AppBar 新增模型管理入口 → 模型管理页支持 HuggingFace 断点续传下载 → 下载后自动生效 → 无模型时功能入口门控拦截。

**Architecture:** 新增 `AvailableModel` 数据模型 + `ModelDownloadService`（dio HTTP Range）→ `ModelDownloadProvider`（ChangeNotifier 暴露状态）→ `ModelManagePage`（列表 + 进度 UI）。TopicSelectionPage AppBar 加图标入口 + 点击话题时门控检查。

**Tech Stack:** dio (HTTP Range 断点续传), path_provider (沙盒路径), Provider (状态管理)

---

### Task 1: 添加 dio + path_provider 依赖

**Files:**
- Modify: `pubspec.yaml`

**Step 1: 在 dependencies 末尾追加两个包**

```yaml
  dio: ^5.7.0
  path_provider: ^2.1.5
```

**Step 2: flutter pub get**

```bash
flutter pub get
```
期望：成功，无版本冲突。

**Step 3: Commit**

```bash
git add pubspec.yaml pubspec.lock
git commit -m "chore: add dio and path_provider for model download"
```

---

### Task 2: AvailableModel 数据模型

**Files:**
- Create: `lib/core/models/available_model.dart`

**Step 1: 创建数据类**

```dart
import 'package:socratic_ai/core/constants.dart';

/// 可供下载的 AI 模型定义
///
/// 当前 APP 只支持一个活跃模型（下载即生效），
/// 但 [available] 列表预留了多模型扩展空间。
class AvailableModel {
  final String id;
  final String name;
  final String description;
  final String quant;
  final int sizeBytes;
  final String fileName;

  const AvailableModel({
    required this.id,
    required this.name,
    required this.description,
    required this.quant,
    required this.sizeBytes,
    required this.fileName,
  });

  String get downloadUrl =>
      'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/$fileName';

  String get mirrorUrl =>
      'https://hf-mirror.com/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/$fileName';

  /// MVP 可用模型列表（目前仅 Qwen2.5-1.5B）
  static const List<AvailableModel> available = [
    AvailableModel(
      id: 'qwen2.5-1.5b-q4km',
      name: 'Qwen2.5-1.5B',
      description: '中文苏格拉底对话，端侧推理',
      quant: 'Q4_K_M',
      sizeBytes: 1130000000,
      fileName: 'qwen2.5-1.5b-instruct-q4_k_m.gguf',
    ),
  ];
}
```

**Step 2: flutter analyze**

```bash
flutter analyze lib/core/models/available_model.dart
```
期望：0 error, 0 warning

**Step 3: Commit**

```bash
git add lib/core/models/available_model.dart
git commit -m "feat: add AvailableModel data class with HuggingFace URLs"
```

---

### Task 3: 更新常量 + isModelAvailable() 门控函数

**Files:**
- Modify: `lib/core/constants.dart`

**Step 1: 在 AppConstants 中追加下载相关常量 + 门控函数**

在当前常量末尾追加：

```dart
  // ─── 模型下载 ───

  /// 沙盒内模型存储子目录
  static const String modelSubDir = 'models';

  /// 模型文件预期大小（字节），用于完整性校验
  static const int modelExpectedSize = 1130000000;
```

**Step 2: 将 defaultModelPath 从 const 改为可变**

当前：
```dart
  static const String defaultModelPath = macosDevModelAbsolutePath;
```

改为：
```dart
  /// 默认模型路径（运行时动态设置）
  /// Day 8 之前使用开发硬编码路径；下载完成后切换为沙盒路径。
  static String defaultModelPath = macosDevModelAbsolutePath;
```

去掉 `const`。同时，因为 `macosDevModelAbsolutePath` 在代码中可能要保留做 fallback，不需要改动它。

**Step 3: 新增 isModelAvailable() 工具函数**

在 `AppConstants` 类内（或独立文件），追加静态方法：

```dart
  /// 检查模型文件是否存在于当前 [defaultModelPath]
  static bool isModelAvailable() {
    return File(defaultModelPath).existsSync();
  }
```

需要在文件顶部加 `import 'dart:io';`。

**Step 4: Commit**

```bash
git add lib/core/constants.dart
git commit -m "feat: add model download constants and isModelAvailable() gating"
```

---

### Task 4: ModelDownloadService — 断点续传核心

**Files:**
- Create: `lib/core/engine/model_download_service.dart`

**Step 1: 创建服务类**

```dart
import 'dart:io';

import 'package:dio/dio.dart';

/// 下载进度回调
typedef DownloadProgress = void Function({
  required int received,
  required int total,
});

/// 模型下载服务（单例）
///
/// 使用 dio HTTP Range 实现断点续传。
/// 同一时刻只能有一个下载任务。
class ModelDownloadService {
  ModelDownloadService._();
  static final instance = ModelDownloadService._();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(minutes: 30),
  ));

  CancelToken? _cancelToken;

  /// 下载模型到 [savePath]，Range 头支持断点续传。
  ///
  /// 返回 true 表示完成，false 表示取消，异常表示失败。
  Future<bool> download({
    required String url,
    required String savePath,
    DownloadProgress? onProgress,
  }) async {
    _cancelToken = CancelToken();

    final file = File(savePath);
    final startByte = await file.exists() ? await file.length() : 0;

    final headers = <String, dynamic>{};
    if (startByte > 0) {
      headers['Range'] = 'bytes=$startByte-';
    }

    try {
      final response = await _dio.download(
        url,
        savePath,
        options: Options(
          headers: headers,
          responseType: ResponseType.stream,
        ),
        cancelToken: _cancelToken,
        onReceiveProgress: (received, total) {
          onProgress?.call(
            received: startByte + received,
            total: startByte + total,
          );
        },
      );

      return response.statusCode == 200 || response.statusCode == 206;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) return false;
      rethrow;
    }
  }

  void cancel() {
    _cancelToken?.cancel();
    _cancelToken = null;
  }
}
```

**Step 2: flutter analyze**

```bash
flutter analyze lib/core/engine/model_download_service.dart
```

**Step 3: Commit**

```bash
git add lib/core/engine/model_download_service.dart
git commit -m "feat: add ModelDownloadService with HTTP Range resume"
```

---

### Task 5: ModelDownloadProvider — 下载状态管理

**Files:**
- Create: `lib/features/chat/providers/model_download_provider.dart`

**Step 1: 创建 Provider**

```dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:socratic_ai/core/constants.dart';
import 'package:socratic_ai/core/engine/model_download_service.dart';
import 'package:socratic_ai/core/models/available_model.dart';

enum DownloadStatus { idle, downloading, completed, failed, cancelled }

/// 单个模型的下载状态
class ModelDownloadState {
  final DownloadStatus status;
  final double progress;   // 0.0 ~ 1.0
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

/// 模型下载状态管理
///
/// 管理下载生命周期：检查本地 → 下载 → 进度 → 完成/失败。
/// 在 main() 的 MultiProvider 中全局注入。
class ModelDownloadProvider extends ChangeNotifier {
  final ModelDownloadService _service = ModelDownloadService.instance;

  /// key = model id, value = 下载状态
  final Map<String, ModelDownloadState> _states = {};

  Timer? _speedTimer;
  int _lastReceived = 0;
  DateTime _lastCheckTime = DateTime.now();
  String? _activeModelId;

  /// 获取指定模型的下载状态
  ModelDownloadState stateOf(String modelId) =>
      _states[modelId] ?? const ModelDownloadState();

  /// 当前活跃模型 ID（下载完成即自动设为活跃）
  String? get activeModelId => _activeModelId;

  /// 模型文件下载保存路径
  Future<String> _savePath(AvailableModel model) async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/${AppConstants.modelSubDir}/${model.fileName}';
  }

  /// 开始下载 [model]
  Future<void> startDownload(AvailableModel model) async {
    final savePath = await _savePath(model);

    _states[model.id] = const ModelDownloadState(status: DownloadStatus.downloading);
    notifyListeners();

    _speedTimer?.cancel();
    _speedTimer = Timer.periodic(const Duration(seconds: 1), (_) => _updateSpeed(model.id));

    try {
      final success = await _service.download(
        url: model.downloadUrl,
        savePath: savePath,
        onProgress: ({required received, required total}) {
          final total_ = total > 0 ? total : model.sizeBytes;
          _states[model.id] = ModelDownloadState(
            status: DownloadStatus.downloading,
            progress: total_ > 0 ? received / total_ : 0,
            receivedBytes: received,
            totalBytes: total_,
            speedText: _states[model.id]?.speedText ?? '',
            etaText: _states[model.id]?.etaText ?? '',
          );
          notifyListeners();
        },
      );

      _speedTimer?.cancel();

      if (success) {
        _states[model.id] = ModelDownloadState(
          status: DownloadStatus.completed,
          progress: 1.0,
          receivedBytes: model.sizeBytes,
          totalBytes: model.sizeBytes,
        );
        _activeModelId = model.id;
        AppConstants.defaultModelPath = savePath;
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
      speedText: _formatSpeed(speedBytes),
      etaText: etaSeconds > 0 ? _formatEta(etaSeconds) : '',
    );
    _lastReceived = state.receivedBytes;
    _lastCheckTime = now;
    notifyListeners();
  }

  /// 取消下载
  void cancelDownload(String modelId) {
    _service.cancel();
    _speedTimer?.cancel();
    _states.remove(modelId);
    notifyListeners();
  }

  /// 检查本地是否已有已下载模型（App 启动时调用一次）
  Future<void> checkLocalModels() async {
    for (final model in AvailableModel.available) {
      final savePath = await _savePath(model);
      final file = File(savePath);
      if (await file.exists() && await file.length() >= model.sizeBytes * 0.99) {
        _states[model.id] = ModelDownloadState(
          status: DownloadStatus.completed,
          progress: 1.0,
          receivedBytes: model.sizeBytes,
          totalBytes: model.sizeBytes,
        );
        _activeModelId = model.id;
        AppConstants.defaultModelPath = savePath;
      }
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _speedTimer?.cancel();
    super.dispose();
  }

  // ─── 格式化工具 ───

  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String _formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond < 1024) return '${bytesPerSecond.toInt()} B/s';
    if (bytesPerSecond < 1024 * 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  static String _formatEta(int seconds) {
    if (seconds < 60) return '剩余 $seconds 秒';
    if (seconds < 3600) return '剩余 ${seconds ~/ 60} 分钟';
    return '剩余 ${seconds ~/ 3600} 小时';
  }
}
```

**Step 2: flutter analyze**

```bash
flutter analyze lib/features/chat/providers/model_download_provider.dart
```

**Step 3: Commit**

```bash
git add lib/features/chat/providers/model_download_provider.dart
git commit -m "feat: add ModelDownloadProvider with progress/speed/ETA/retry"
```

---

### Task 6: 注入 Provider 到 main() + 启动检查

**Files:**
- Modify: `lib/main.dart`

**Step 1: 在 MultiProvider 中加入 ModelDownloadProvider**

当前 main() 中：
```dart
      providers: [
        ChangeNotifierProvider(create: (_) => TopicProvider()),
      ],
```

改为：
```dart
      providers: [
        ChangeNotifierProvider(create: (_) => TopicProvider()),
        ChangeNotifierProvider(create: (_) => ModelDownloadProvider()..checkLocalModels()),
      ],
```

并在文件顶部加 import：
```dart
import 'package:socratic_ai/features/chat/providers/model_download_provider.dart';
```

> `..checkLocalModels()` 在 Provider 创建后立即调用，扫描沙盒内是否已有模型文件。

**Step 2: Commit**

```bash
git add lib/main.dart
git commit -m "feat: inject ModelDownloadProvider and auto-check local models"
```

---

### Task 7: ModelManagePage — 模型管理 UI

**Files:**
- Create: `lib/features/chat/model_manage_page.dart`

**Step 1: 创建页面**

```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:socratic_ai/core/models/available_model.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/chat/providers/model_download_provider.dart';

/// 模型管理页
///
/// 展示可用模型列表 + 下载交互。
/// 当前 APP 只有一个活跃模型，下载完成即自动启用。
class ModelManagePage extends StatelessWidget {
  const ModelManagePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('模型管理'),
        backgroundColor: AppTheme.background,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      backgroundColor: AppTheme.background,
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: AvailableModel.available.length,
        itemBuilder: (context, index) {
          final model = AvailableModel.available[index];
          return _ModelCard(model: model);
        },
      ),
    );
  }
}

class _ModelCard extends StatelessWidget {
  final AvailableModel model;

  const _ModelCard({required this.model});

  @override
  Widget build(BuildContext context) {
    return Consumer<ModelDownloadProvider>(
      builder: (context, provider, _) {
        final state = provider.stateOf(model.id);

        return Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.grey.shade200),
          ),
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题行
                Row(
                  children: [
                    const Icon(Icons.memory, size: 28, color: AppTheme.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            model.name,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            model.description,
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _buildAction(context, provider, state),
                  ],
                ),

                const SizedBox(height: 10),

                // 模型详情
                Text(
                  '${model.quant} 量化 · ${ModelDownloadProvider.formatBytes(model.sizeBytes)}',
                  style: const TextStyle(fontSize: 12, color: Colors.black38),
                ),

                // 下载进度条
                if (state.status == DownloadStatus.downloading) ...[
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: state.progress > 0 ? state.progress : null,
                      minHeight: 6,
                      backgroundColor: Colors.grey.shade200,
                      valueColor: const AlwaysStoppedAnimation(AppTheme.primary),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${(state.progress * 100).toInt()}%',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        state.speedText,
                        style: const TextStyle(fontSize: 12, color: Colors.black45),
                      ),
                      Text(
                        state.etaText,
                        style: const TextStyle(fontSize: 12, color: Colors.black45),
                      ),
                    ],
                  ),
                ],

                // 失败消息
                if (state.status == DownloadStatus.failed && state.error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    state.error!,
                    style: const TextStyle(fontSize: 12, color: AppTheme.error),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],

                // 完成提示
                if (state.status == DownloadStatus.completed) ...[
                  const SizedBox(height: 4),
                  const Text(
                    '模型已就绪，可以开始对话了',
                    style: TextStyle(fontSize: 12, color: AppTheme.primary),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAction(
    BuildContext context,
    ModelDownloadProvider provider,
    ModelDownloadState state,
  ) {
    switch (state.status) {
      case DownloadStatus.idle:
      case DownloadStatus.cancelled:
      case DownloadStatus.failed:
        return OutlinedButton.icon(
          onPressed: () => provider.startDownload(model),
          icon: const Icon(Icons.download, size: 18),
          label: const Text('下载'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppTheme.primary,
            side: const BorderSide(color: AppTheme.primary),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );

      case DownloadStatus.downloading:
        return TextButton(
          onPressed: () => provider.cancelDownload(model.id),
          child: const Text('取消', style: TextStyle(color: AppTheme.textSecondary)),
        );

      case DownloadStatus.completed:
        return const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle, color: AppTheme.primary, size: 22),
            SizedBox(width: 4),
            Text('已就绪', style: TextStyle(color: AppTheme.primary, fontSize: 13)),
          ],
        );
    }
  }
}
```

**Step 2: flutter analyze**

```bash
flutter analyze lib/features/chat/model_manage_page.dart
```
期望：0 error, 0 warning

**Step 3: Commit**

```bash
git add lib/features/chat/model_manage_page.dart
git commit -m "feat: add ModelManagePage with download progress UI"
```

---

### Task 8: TopicSelectionPage — 加模型入口 + 门控拦截

**Files:**
- Modify: `lib/features/topics/topic_selection_page.dart`

**Step 1: 在 AppBar actions 中加模型图标按钮**

在现有 history 按钮**之前**插入：

```dart
        actions: [
          // ── NEW: 模型管理入口 ──
          IconButton(
            icon: const Icon(Icons.memory, color: AppTheme.textSecondary),
            tooltip: '模型管理',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const ModelManagePage(),
                ),
              );
            },
          ),
          // ── 现有: 历史记录 ──
          IconButton(
            icon: const Icon(Icons.history, color: AppTheme.textSecondary),
            ...
```

需要加 import：
```dart
import 'package:socratic_ai/features/chat/model_manage_page.dart';
```

**Step 2: 话题卡片 onTap 加门控**

在 `TopicCard` 的 `onTap` 回调开头加检查：

当前：
```dart
onTap: (t) {
  context.read<TopicProvider>().selectTopic(t.title);
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => ChatPage(topic: t.title)),
  );
},
```

改为：
```dart
onTap: (t) {
  if (!AppConstants.isModelAvailable()) {
    _showModelRequiredSnackBar(context);
    return;
  }
  context.read<TopicProvider>().selectTopic(t.title);
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => ChatPage(topic: t.title)),
  );
},
```

**Step 3: 自定义话题 onSubmitted 加门控**

当前：
```dart
onSubmitted: (value) {
  final trimmed = value.trim();
  if (trimmed.isNotEmpty) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChatPage(topic: trimmed)),
    );
  } else {
    SnackBarThrottle.show(context, '请输入话题内容');
  }
},
```

改为：
```dart
onSubmitted: (value) {
  if (!AppConstants.isModelAvailable()) {
    _showModelRequiredSnackBar(context);
    return;
  }
  final trimmed = value.trim();
  if (trimmed.isNotEmpty) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChatPage(topic: trimmed)),
    );
  } else {
    SnackBarThrottle.show(context, '请输入话题内容');
  }
},
```

**Step 4: 加 SnackBar 辅助方法**

在文件底部（`TopicSelectionPage` 类外部）添加：

```dart
void _showModelRequiredSnackBar(BuildContext context) {
  SnackBarThrottle.show(context, '请先下载 AI 模型');
  // 防止 SnackBar 自动消失后用户不知道去哪下载，不做 auto-dismiss 跳转
  // 用户可以自己点击 AppBar 的模型图标
}
```

或者用带 action 的 SnackBar：

```dart
void _showModelRequiredSnackBar(BuildContext context) {
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: const Text('请先下载 AI 模型'),
      action: SnackBarAction(
        label: '去下载',
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ModelManagePage()),
          );
        },
      ),
      duration: const Duration(seconds: 4),
    ),
  );
}
```

> 推荐后者——有「去下载」action，避免 SnackBar 消失后用户困惑。

**Step 5: Commit**

```bash
git add lib/features/topics/topic_selection_page.dart
git commit -m "feat: add model management entry and feature gating on topic selection"
```

---

### Task 9: 测试 + 最终验证

**Files:**
- Create: `test/features/chat/model_download_provider_test.dart`

**Step 1: 写单元测试**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:socratic_ai/features/chat/providers/model_download_provider.dart';

void main() {
  group('ModelDownloadProvider formatting', () {
    test('formatBytes', () {
      expect(ModelDownloadProvider.formatBytes(0), '0 B');
      expect(ModelDownloadProvider.formatBytes(1024), '1.0 KB');
      expect(ModelDownloadProvider.formatBytes(1048576), '1.0 MB');
      expect(ModelDownloadProvider.formatBytes(1073741824), '1.00 GB');
    });

    test('initial state is idle for unknown model', () {
      final provider = ModelDownloadProvider();
      final state = provider.stateOf('unknown');
      expect(state.status, DownloadStatus.idle);
      expect(state.progress, 0.0);
      expect(state.error, isNull);
    });

    test('activeModelId is null initially', () {
      final provider = ModelDownloadProvider();
      expect(provider.activeModelId, isNull);
    });
  });
}

```

**Step 2: 运行测试**

```bash
flutter test test/features/chat/model_download_provider_test.dart
```
期望：3/3 通过

**Step 3: 全量 analyze + test**

```bash
flutter analyze lib/ test/
flutter test
```
期望：analyze 0 error 0 warning，所有已有测试通过。

**Step 4: Commit**

```bash
git add test/features/chat/model_download_provider_test.dart
git commit -m "test: add ModelDownloadProvider unit tests"
```

---

## 验收标准对照

| # | 标准 | 实现位置 |
|:--:|------|------|
| 1 | 话题页 AppBar 有模型图标入口 | `TopicSelectionPage.actions` → `Icons.memory` |
| 2 | 模型管理页列出可下载模型 | `ModelManagePage` → `AvailableModel.available` |
| 3 | 下载进度条实时更新百分比 + 速度 + ETA | `ModelDownloadProvider._updateSpeed()` → `_ModelCard` |
| 4 | 断点续传（网络中断恢复） | `ModelDownloadService` HTTP Range 头 |
| 5 | 下载完成自动设为活跃模型 | `startDownload()` 完成时设 `_activeModelId` + `defaultModelPath` |
| 6 | 下次启动跳过重复下载 | `checkLocalModels()` 扫描沙盒 → 已达标的直接 completed |
| 7 | 下载失败 → 重试 | `_ModelCard._buildAction` 中 failed 状态显示下载按钮 |
| 8 | 无模型时话题入口拦截 | `TopicSelectionPage` onTap + onSubmitted → `_showModelRequiredSnackBar` |
| 9 | HistoryPage 不需要模型，不拦截 | 无改动（本来就不走 ChatPage 链路） |

---

## 文件变更清单

| 操作 | 文件 |
|:--:|------|
| 修改 | `pubspec.yaml` (+dio, +path_provider) |
| 新建 | `lib/core/models/available_model.dart` |
| 修改 | `lib/core/constants.dart` (+常量, +isModelAvailable) |
| 新建 | `lib/core/engine/model_download_service.dart` |
| 新建 | `lib/features/chat/providers/model_download_provider.dart` |
| 新建 | `lib/features/chat/model_manage_page.dart` |
| 修改 | `lib/main.dart` (+Provider 注入) |
| 修改 | `lib/features/topics/topic_selection_page.dart` (+图标, +门控) |
| 新建 | `test/features/chat/model_download_provider_test.dart` |

**总计：5 新建 + 4 修改 = 9 个 tasks，预计 6-7 commits。**

---

## 执行选项

Plan complete and saved to `docs/plans/2026-07-10-day8-model-download-v3.md`. Two execution options:

1. **Subagent-Driven (this session)** — 分派子代理并行跑独立 task（Task 2+3+4 可并行），review 每步，快速迭代

2. **Sequential (this session)** — 我按 1→9 顺序逐个做，每步 commit

Which approach?
