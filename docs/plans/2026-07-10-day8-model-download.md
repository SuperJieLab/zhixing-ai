# Day 8 — 模型下载 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 首次启动自动从 HuggingFace 下载 Qwen 1.5B GGUF 模型到沙盒，支持断点续传 + 进度条 + 失败重试。

**Architecture:** 新增 `ModelDownloadService`（dio 断点续传）→ `ModelDownloadProvider`（ChangeNotifier 暴露进度状态）→ `DownloadPage`（全屏进度 UI）。启动流程改造：`main()` 检查模型是否存在 → 不存在则展示 DownloadPage → 下载完成自动导航到 TopicSelectionPage。已下载则直接跳过。

**Tech Stack:** dio (HTTP Range 断点续传), path_provider (沙盒路径), Provider (状态管理)

---

## 前置状态

当前模型路径硬编码在 `constants.dart` 的开发绝对路径：
```dart
static const String macosDevModelAbsolutePath =
    '/Users/superjie-mac/projects/socratic-ai/assets/models/qwen3.5-2b-q4_k_m.gguf';
```

现有 `LlamaService.ensureReady()` 用 `AppConstants.defaultModelPath` 加载。Day 8 需要将此路径改为沙盒内的下载路径。

---

### Task 1: 添加 dio + path_provider 依赖

**Files:**
- Modify: `pubspec.yaml`

**Step 1: 更新 pubspec.yaml**

在 `dependencies` 中添加：
```yaml
  dio: ^5.7.0
  path_provider: ^2.1.5
```

注意：直接在现有 dependency 列表末尾追加，不要破坏已有条目。

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

### Task 2: 更新常量 — HuggingFace URL + 沙盒路径

**Files:**
- Modify: `lib/core/constants.dart`

**Step 1: 新增下载相关常量**

在 `AppConstants` 类的 LLM 模型配置区块追加：

```dart
  // ─── 模型下载配置 ───

  /// HuggingFace GGUF 直链（Qwen2.5-1.5B-Instruct, Q4_K_M 量化, ~1.06GB）
  static const String modelDownloadUrl =
      'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/'
      'qwen2.5-1.5b-instruct-q4_k_m.gguf';

  /// hf-mirror.com 国内镜像（备选，下载更快）
  static const String modelDownloadMirrorUrl =
      'https://hf-mirror.com/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/'
      'qwen2.5-1.5b-instruct-q4_k_m.gguf';

  /// 模型文件预期大小（字节），用于校验完整性
  static const int modelExpectedSize = 1130000000; // ~1.06GB

  /// 沙盒内的模型存储子目录
  static const String modelSubDir = 'models';
```

**Step 2: 将 defaultModelPath 改为动态计算**

保留旧常量（开发调试用），但 `defaultModelPath` 不做硬编码——留给 Task 7 的 startup gate 动态指定：

```dart
  // ⚠️ 以下为开发期硬编码，Day 8 模型下载完成后废弃
  static const String macosDevModelAbsolutePath =
      '/Users/superjie-mac/projects/socratic-ai/assets/models/qwen3.5-2b-q4_k_m.gguf';

  /// 默认模型路径（运行时动态设置，启动阶段由 main() 注入）
  /// Day 8 之前使用开发硬编码路径；Day 8 之后使用沙盒下载路径。
  static String defaultModelPath = macosDevModelAbsolutePath;
```

> 注：这里用 `static String`（可变）替代原来的 `static const`，让启动阶段可以动态设置。

**Step 3: Commit**

```bash
git add lib/core/constants.dart
git commit -m "feat: add HuggingFace download URL and sandbox path constants"
```

---

### Task 3: ModelDownloadService — 断点续传核心

**Files:**
- Create: `lib/core/engine/model_download_service.dart`

**Step 1: 创建服务类**

```dart
import 'dart:io';

import 'package:dio/dio.dart';

import 'package:socratic_ai/core/constants.dart';

/// 下载进度回调
typedef DownloadProgressCallback = void Function({
  required int received,
  required int total,
  required double speed, // bytes/s
});

/// 模型下载服务
///
/// 使用 dio HTTP Range 实现断点续传：
/// - 首次下载：Range: bytes=0-
/// - 中断后恢复：Range: bytes=<已有字节数>-
///
/// 单例，因为同一时刻只能有一个下载任务。
class ModelDownloadService {
  ModelDownloadService._();
  static final ModelDownloadService instance = ModelDownloadService._();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(minutes: 30), // 1GB 可能很久
  ));

  CancelToken? _cancelToken;

  /// 下载模型到 [savePath]，支持断点续传
  ///
  /// 返回 true 表示下载完成，false 表示被取消。
  /// 抛出异常表示下载失败（网络错误、磁盘满等）。
  Future<bool> download({
    required String url,
    required String savePath,
    DownloadProgressCallback? onProgress,
  }) async {
    _cancelToken = CancelToken();

    final file = File(savePath);
    final startByte = await file.exists() ? await file.length() : 0;

    // 如果文件已存在且大小匹配，跳过下载
    if (startByte > 0 && startByte == AppConstants.modelExpectedSize) {
      onProgress?.call(
        received: startByte,
        total: startByte,
        speed: 0,
      );
      return true;
    }

    // 如果已有部分文件比预期还大（损坏），删除重来
    if (startByte >= AppConstants.modelExpectedSize) {
      await file.delete();
    }

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
          final actualReceived = startByte + received;
          final actualTotal = startByte + total;
          onProgress?.call(
            received: actualReceived,
            total: actualTotal,
            speed: 0, // dio 的 onReceiveProgress 不提供速度，由 Provider 计算
          );
        },
      );

      return response.statusCode == 200 || response.statusCode == 206;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        return false;
      }
      rethrow;
    }
  }

  /// 取消正在进行的下载
  void cancel() {
    _cancelToken?.cancel();
    _cancelToken = null;
  }

  /// 获取远程文件大小（HEAD 请求）
  Future<int> getRemoteFileSize(String url) async {
    try {
      final response = await _dio.head(url);
      final length = response.headers.value('content-length');
      return length != null ? int.parse(length) : -1;
    } catch (_) {
      return -1;
    }
  }
}
```

**Step 2: flutter analyze**

```bash
flutter analyze lib/core/engine/model_download_service.dart
```
期望：0 error, 0 warning

**Step 3: Commit**

```bash
git add lib/core/engine/model_download_service.dart
git commit -m "feat: add ModelDownloadService with HTTP Range resume support"
```

---

### Task 4: ModelDownloadProvider — 下载状态管理

**Files:**
- Create: `lib/features/chat/providers/model_download_provider.dart`

**Step 1: 创建 Provider**

```dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:socratic_ai/core/constants.dart';
import 'package:socratic_ai/core/engine/model_download_service.dart';

/// 下载阶段
enum DownloadPhase {
  /// 初始状态（尚未检查模型）
  idle,

  /// 正在检查本地是否有已下载的模型
  checking,

  /// 正在下载
  downloading,

  /// 下载完成（模型就绪）
  completed,

  /// 下载失败
  failed,

  /// 已取消
  cancelled,
}

/// 模型下载状态管理
///
/// 管理整个下载生命周期：
/// 1. 检查沙盒是否已有模型 → completed
/// 2. 无模型 → 自动开始下载 → 进度更新 → completed
/// 3. 下载失败 → 暴露 error + retry
///
/// 从 TopicSelectionPage / ChatPage 注入（非全局，因为只启动时用一次）。
class ModelDownloadProvider extends ChangeNotifier {
  final ModelDownloadService _service = ModelDownloadService.instance;

  DownloadPhase _phase = DownloadPhase.idle;
  double _progress = 0.0; // 0.0 ~ 1.0
  String _speedText = ''; // "2.3 MB/s"
  String _etaText = '';   // "剩余 3 分钟"
  String? _error;
  int _receivedBytes = 0;
  int _totalBytes = 0;

  Timer? _speedTimer;
  int _lastReceived = 0;
  DateTime _lastCheckTime = DateTime.now();

  // ─── Getters ───

  DownloadPhase get phase => _phase;
  double get progress => _progress;
  String get speedText => _speedText;
  String get etaText => _etaText;
  String? get error => _error;
  int get receivedBytes => _receivedBytes;
  int get totalBytes => _totalBytes;

  /// 百分比显示文本（如 "42%"）
  String get progressPercent => '${(_progress * 100).toInt()}%';

  /// 大小显示文本（如 "456 MB / 1.06 GB"）
  String get sizeText {
    final received = _formatBytes(_receivedBytes);
    final total = _formatBytes(_totalBytes > 0 ? _totalBytes : AppConstants.modelExpectedSize);
    return '$received / $total';
  }

  /// 模型沙盒保存路径
  Future<String> get _modelSavePath async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/${AppConstants.modelSubDir}/${AppConstants.modelFileName}';
  }

  // ─── 公开方法 ───

  /// 检查并开始下载（如果本地没有模型）
  ///
  /// 应在 App 启动时调用一次。
  Future<void> checkAndDownload() async {
    _phase = DownloadPhase.checking;
    notifyListeners();

    try {
      final savePath = await _modelSavePath;
      final file = File(savePath);

      // 本地已有完整模型 → 直接完成
      if (await file.exists() && await file.length() == AppConstants.modelExpectedSize) {
        _phase = DownloadPhase.completed;
        _progress = 1.0;
        AppConstants.defaultModelPath = savePath;
        notifyListeners();
        return;
      }

      // 无模型 → 开始下载
      await _startDownload(savePath);
    } catch (e) {
      _phase = DownloadPhase.failed;
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> _startDownload(String savePath) async {
    _phase = DownloadPhase.downloading;
    _progress = 0.0;
    _error = null;
    notifyListeners();

    // 速度计算定时器（每秒更新）
    _speedTimer?.cancel();
    _speedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateSpeed();
    });

    try {
      final success = await _service.download(
        url: AppConstants.modelDownloadUrl,
        savePath: savePath,
        onProgress: ({required received, required total, required speed}) {
          _receivedBytes = received;
          _totalBytes = total;
          _progress = total > 0 ? received / total : 0;
          notifyListeners();
        },
      );

      _speedTimer?.cancel();

      if (success) {
        _phase = DownloadPhase.completed;
        _progress = 1.0;
        AppConstants.defaultModelPath = savePath;
      } else {
        _phase = DownloadPhase.cancelled;
      }
      notifyListeners();
    } catch (e) {
      _speedTimer?.cancel();
      _phase = DownloadPhase.failed;
      _error = '下载失败：${e.toString()}';
      notifyListeners();
    }
  }

  void _updateSpeed() {
    final now = DateTime.now();
    final elapsed = now.difference(_lastCheckTime).inMilliseconds / 1000.0;
    if (elapsed <= 0) return;

    final delta = _receivedBytes - _lastReceived;
    final speedBytes = delta / elapsed; // bytes/s
    _speedText = _formatSpeed(speedBytes);

    // 计算 ETA
    final remaining = _totalBytes - _receivedBytes;
    if (speedBytes > 0 && remaining > 0) {
      final etaSeconds = (remaining / speedBytes).round();
      _etaText = _formatEta(etaSeconds);
    }

    _lastReceived = _receivedBytes;
    _lastCheckTime = now;
    notifyListeners();
  }

  /// 重试下载
  Future<void> retry() async {
    _error = null;
    final savePath = await _modelSavePath;
    // 删除可能损坏的残留文件
    final file = File(savePath);
    if (await file.exists()) await file.delete();
    await _startDownload(savePath);
  }

  /// 取消下载
  void cancel() {
    _service.cancel();
    _speedTimer?.cancel();
    _phase = DownloadPhase.cancelled;
    notifyListeners();
  }

  /// 跳过下载（开发调试用——使用本地已有的模型文件）
  void skipAndUseLocal(String localPath) {
    _phase = DownloadPhase.completed;
    _progress = 1.0;
    AppConstants.defaultModelPath = localPath;
    notifyListeners();
  }

  @override
  void dispose() {
    _speedTimer?.cancel();
    super.dispose();
  }

  // ─── 格式化工具 ───

  static String _formatBytes(int bytes) {
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
    return '剩余 ${seconds ~/ 3600} 小时 ${(seconds % 3600) ~/ 60} 分钟';
  }
}
```

> ⚠️ `path_provider` 需要 `import 'dart:io'` —— `getApplicationDocumentsDirectory()` 是平台方法，在 Dart 测试环境中调用会失败。测试中需要 mock。

**Step 2: flutter analyze**

```bash
flutter analyze lib/features/chat/providers/model_download_provider.dart
```
期望：0 error, 0 warning

**Step 3: Commit**

```bash
git add lib/features/chat/providers/model_download_provider.dart
git commit -m "feat: add ModelDownloadProvider with progress, speed, ETA, retry"
```

---

### Task 5: DownloadPage — 全屏下载 UI

**Files:**
- Create: `lib/features/chat/download_page.dart`

**Step 1: 创建下载页面**

```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/chat/providers/model_download_provider.dart';

/// 模型下载全屏页
///
/// 四种状态：
/// - checking: 旋转指示器「正在检查模型...」
/// - downloading: 进度条 + 百分比 + 速度 + ETA + 取消按钮
/// - failed: 红色错误 + 重试按钮 + 跳过按钮（开发用）
/// - cancelled: 提示 + 重新开始按钮
class DownloadPage extends StatelessWidget {
  const DownloadPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Consumer<ModelDownloadProvider>(
            builder: (context, provider, _) {
              switch (provider.phase) {
                case DownloadPhase.idle:
                case DownloadPhase.checking:
                  return _buildChecking();
                case DownloadPhase.downloading:
                  return _buildDownloading(context, provider);
                case DownloadPhase.failed:
                  return _buildFailed(context, provider);
                case DownloadPhase.cancelled:
                  return _buildCancelled(context, provider);
                case DownloadPhase.completed:
                  // 正常不应渲染此状态——completed 后立即导航走
                  return _buildChecking();
              }
            },
          ),
        ),
      ),
    );
  }

  Widget _buildChecking() {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 48,
          height: 48,
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
        SizedBox(height: 24),
        Text(
          '正在检查模型...',
          style: TextStyle(fontSize: 16, color: Colors.black54),
        ),
      ],
    );
  }

  Widget _buildDownloading(BuildContext context, ModelDownloadProvider provider) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题
          const Text(
            '正在准备 AI 思考引擎',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            '(~${_formatSize(provider.totalBytes)})',
            style: const TextStyle(fontSize: 14, color: Colors.black45),
          ),
          const SizedBox(height: 40),

          // 进度条
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: provider.progress > 0 ? provider.progress : null,
              minHeight: 8,
              backgroundColor: Colors.grey.shade200,
              valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.primary),
            ),
          ),
          const SizedBox(height: 16),

          // 百分比 + 大小
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                provider.progressPercent,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.primary,
                ),
              ),
              Text(
                provider.sizeText,
                style: const TextStyle(fontSize: 14, color: Colors.black54),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // 速度 + ETA
          if (provider.speedText.isNotEmpty)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _InfoChip(icon: Icons.speed, text: provider.speedText),
                const SizedBox(width: 24),
                _InfoChip(icon: Icons.timer_outlined, text: provider.etaText),
              ],
            ),
          const SizedBox(height: 40),

          // 取消按钮
          OutlinedButton.icon(
            onPressed: () => provider.cancel(),
            icon: const Icon(Icons.close, size: 18),
            label: const Text('取消下载'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.black54,
              side: const BorderSide(color: Colors.black26),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFailed(BuildContext context, ModelDownloadProvider provider) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 56, color: AppTheme.error),
          const SizedBox(height: 16),
          const Text(
            '模型下载失败',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            provider.error ?? '未知错误',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: Colors.black54),
          ),
          const SizedBox(height: 32),
          ElevatedButton.icon(
            onPressed: () => provider.retry(),
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.white,
              minimumSize: const Size(200, 48),
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () {
              // 开发调试：跳过下载，使用本地模型
              provider.skipAndUseLocal(AppConstants.macosDevModelAbsolutePath);
            },
            child: const Text('跳过下载（使用本地模型）'),
          ),
        ],
      ),
    );
  }

  Widget _buildCancelled(BuildContext context, ModelDownloadProvider provider) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.download_for_offline_outlined, size: 56, color: Colors.black38),
        const SizedBox(height: 16),
        const Text(
          '下载已取消',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        const Text(
          'AI 模型需要下载后才能使用',
          style: TextStyle(fontSize: 14, color: Colors.black54),
        ),
        const SizedBox(height: 32),
        ElevatedButton.icon(
          onPressed: () => provider.retry(),
          icon: const Icon(Icons.download),
          label: const Text('重新下载'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primary,
            foregroundColor: Colors.white,
            minimumSize: const Size(200, 48),
          ),
        ),
      ],
    );
  }

  static String _formatSize(int bytes) {
    if (bytes <= 0) return '1.06 GB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

/// 速度/ETA 小标签
class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String text;

  const _InfoChip({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: Colors.black45),
        const SizedBox(width: 4),
        Text(text, style: const TextStyle(fontSize: 13, color: Colors.black54)),
      ],
    );
  }
}
```

**Step 2: flutter analyze**

```bash
flutter analyze lib/features/chat/download_page.dart
```
期望：0 error, 0 warning（检查 theme 引用——`AppTheme.primary` 和 `AppTheme.error` 需存在）

**Step 3: Commit**

```bash
git add lib/features/chat/download_page.dart
git commit -m "feat: add DownloadPage with progress bar, speed, ETA, retry UI"
```

---

### Task 6: 主题补充 error 色（若缺失）

**Files:**
- Modify: `lib/core/theme.dart`（仅当不存在 `AppTheme.error` 和 `AppTheme.primary` 时）

**Step 1: 检查主题常量**

```bash
grep -n "static.*Color" lib/core/theme.dart
```

确认 `static const Color primary` 和 `static const Color error` 已存在。如果 `error` 不存在（今天 review 修复已添加），补充：

```dart
  /// 错误/危险色（红色系）
  static const Color error = Color(0xFFC44E4E);
```

如果不存在 `primary`，补充：
```dart
  /// 主色
  static const Color primary = Color(0xFF6B8F71); // 鼠尾草绿
```

**Step 2: Commit**（如需要）

```bash
git add lib/core/theme.dart
git commit -m "fix: ensure AppTheme.primary and AppTheme.error exist for DownloadPage"
```

---

### Task 7: 启动流程改造 — main() + StartupGate

**Files:**
- Modify: `lib/main.dart`
- Create: `lib/app.dart`（替换为启动门逻辑）

这是连接所有组件的关键步骤。

**Step 1: 改造 main.dart**

```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:socratic_ai/app.dart';
import 'package:socratic_ai/core/repository/conversation_repository.dart';
import 'package:socratic_ai/features/chat/providers/model_download_provider.dart';
import 'package:socratic_ai/features/topics/providers/topic_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化本地数据库
  await ConversationRepository.initialize();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => TopicProvider()),
        ChangeNotifierProvider(create: (_) => ModelDownloadProvider()),
      ],
      child: const SocraticApp(),
    ),
  );
}
```

> 改动：在 `providers` 列表中加入 `ModelDownloadProvider`。

**Step 2: 改造 app.dart — 加入启动门**

```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/chat/download_page.dart';
import 'package:socratic_ai/features/chat/providers/model_download_provider.dart';
import 'package:socratic_ai/features/topics/topic_selection_page.dart';

class SocraticApp extends StatelessWidget {
  const SocraticApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Socratic AI',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      home: const _StartupGate(),
    );
  }
}

/// 启动门：根据模型下载状态决定展示哪一个页面
///
/// - 模型未就绪 → DownloadPage（下载进度 / 错误 / 重试）
/// - 模型就绪 → TopicSelectionPage（正常流程）
class _StartupGate extends StatefulWidget {
  const _StartupGate();

  @override
  State<_StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<_StartupGate> {
  @override
  void initState() {
    super.initState();
    // 页面 build 后立即触发下载检查
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ModelDownloadProvider>().checkAndDownload();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ModelDownloadProvider>(
      builder: (context, provider, _) {
        if (provider.phase == DownloadPhase.completed) {
          return const TopicSelectionPage();
        }
        return const DownloadPage();
      },
    );
  }
}
```

> 关键设计：
> - `_StartupGate` 是 `StatefulWidget`，在 `initState` 中通过 `addPostFrameCallback` 触发检查（确保 Provider 已就绪）。
> - 使用 `Consumer<ModelDownloadProvider>` 监听 `phase` 变化：completed → 切换到 TopicSelectionPage。
> - 完成时 `AppConstants.defaultModelPath` 已更新为沙盒路径，后续 `LlamaService.ensureReady()` 自动使用新路径。

**Step 3: flutter analyze**

```bash
flutter analyze lib/main.dart lib/app.dart lib/features/chat/download_page.dart lib/features/chat/providers/model_download_provider.dart
```
期望：0 error, 0 warning

**Step 4: Commit**

```bash
git add lib/main.dart lib/app.dart
git commit -m "feat: add StartupGate to trigger model download before main flow"
```

---

### Task 8: 集成测试 + verify

**Files:**
- Create: `test/features/chat/model_download_provider_test.dart`

**Step 1: 写单元测试（Provider 核心逻辑）**

由于 `ModelDownloadService` 依赖网络和 `path_provider`（平台方法），Provider 层测试应 mock Service。

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:socratic_ai/features/chat/providers/model_download_provider.dart';

void main() {
  group('ModelDownloadProvider', () {
    test('initial state is idle', () {
      final provider = ModelDownloadProvider();
      expect(provider.phase, DownloadPhase.idle);
      expect(provider.progress, 0.0);
      expect(provider.error, isNull);
      expect(provider.speedText, '');
      expect(provider.etaText, '');
    });

    test('progressPercent formats correctly', () {
      // Can't easily test without mocking _startDownload,
      // but we can test formatting
      expect(ModelDownloadProvider._formatBytes(0), '0 B');
      expect(ModelDownloadProvider._formatBytes(1024), '1.0 KB');
      expect(ModelDownloadProvider._formatBytes(1048576), '1.0 MB');
      expect(ModelDownloadProvider._formatBytes(1073741824), '1.00 GB');
    });

    test('_formatSpeed formats correctly', () {
      expect(ModelDownloadProvider._formatSpeed(500), '500 B/s');
      expect(ModelDownloadProvider._formatSpeed(2048), '2.0 KB/s');
      expect(ModelDownloadProvider._formatSpeed(3145728), '3.0 MB/s');
    });

    test('_formatEta formats correctly', () {
      expect(ModelDownloadProvider._formatEta(30), '剩余 30 秒');
      expect(ModelDownloadProvider._formatEta(90), '剩余 1 分钟');
      expect(ModelDownloadProvider._formatEta(3661), '剩余 1 小时 1 分钟');
    });
  });
}
```

> 注：format 方法在 Provider 中是 `static`，需要改为公开（去掉 `_` 前缀）才能测试。或把格式化逻辑抽到独立工具方法。
>
> **调整**：把 `_formatBytes`、`_formatSpeed`、`_formatEta` 改为公共 static 方法（去掉前导 `_`），测试直接引用。

**Step 2: 更新 Provider（format 方法改为 public）**

```bash
# 在 model_download_provider.dart 中：
# _formatBytes → formatBytes
# _formatSpeed → formatSpeed  
# _formatEta → formatEta
```

**Step 3: 运行测试**

```bash
flutter test test/features/chat/model_download_provider_test.dart
```
期望：4/4 通过

**Step 4: 全量 analyze + test**

```bash
flutter analyze lib/ test/
flutter test
```
期望：analyze 0 error 0 warning；已有测试全过。

**Step 5: Commit**

```bash
git add test/features/chat/model_download_provider_test.dart lib/features/chat/providers/model_download_provider.dart
git commit -m "test: add ModelDownloadProvider unit tests for formatting"
```

---

## 验收标准对照

| # | 验收标准 | 实现 |
|:--:|------|------|
| 1 | HuggingFace 直链正常可访问 | `AppConstants.modelDownloadUrl` → dio download |
| 2 | 下载进度实时更新百分比 + 速度 | `onReceiveProgress` → Provider → UI（百分比 + MB/s + ETA） |
| 3 | 网络中断 → 恢复后断点继续 | `startByte = file.length()` → `Range: bytes=startByte-` |
| 4 | 下载完成 → 自动加载模型 | `StartupGate` 检测 `completed` → 导航到 TopicSelectionPage；`LlamaService` 从 `defaultModelPath`（沙盒路径）加载 |
| 5 | 已下载 → 下次跳过 | `checkAndDownload()` 检测文件存在 + 大小匹配 → 直接 completed |
| 6 | 下载失败 → 重试 + 手动选择 | `DownloadPage` 错误状态：retry 按钮 + skip 按钮 |
| 7 | 存储空间不足 → 提示 | dio 抛出 `FileSystemException` → Provider catch → `_error` 显示 |

---

## 执行选项

**Plan complete and saved to `docs/plans/2026-07-10-day8-model-download.md`. Two execution options:**

**1. Subagent-Driven (this session)** — I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Sequential (this session)** — I execute tasks one by one in order, reviewing each commit

**Which approach?**
