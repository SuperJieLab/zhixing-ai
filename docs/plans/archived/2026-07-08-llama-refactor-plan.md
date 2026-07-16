# LlamaService 重构实施计划

> **For CodeBuddy:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将 LlamaService 从"引擎 + Chat 封装"重构为"纯引擎缓存池"，配置内聚，调用方简化。

**Architecture:** LlamaService 单例 + 内建 `Map<LlamaConfig, Future<LlamaEngine>>` 缓存池。三层 API（默认/指定模型/完全自定义）。libraryPath 和平台判断内聚到 `_loadEngine()`。删除所有 Chat 封装方法，调用方直接 `engine.createChat()`。

**Tech Stack:** Dart, llama_cpp_dart, Flutter

**涉及文件:** `llama_service.dart`(重写), `socratic_prompter.dart`(换参数), `insight_service.dart`(换参数), `graph_service.dart`(换参数), `mindmap_service.dart`(内部走池), `chat_provider.dart`(简化), `insights_page.dart`(删除引用), `constants.dart`(新增默认路径)

---

### Task 1: 重写 llama_service.dart — 新增 LlamaConfig + 缓存池核心

**Files:**
- Modify: `lib/core/engine/llama_service.dart`（全量重写）

**Step 1: 备份当前文件（仅作参考，不提交）**

```bash
cp lib/core/engine/llama_service.dart lib/core/engine/llama_service.dart.bak
```

**Step 2: 写入新文件**

完整替代内容（LlamaConfig 值对象 + 缓存池 + 三层 API + 平台路径内聚）：

```dart
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';

import 'package:socratic_ai/core/constants.dart';

/// 模型加载配置（值对象，决定缓存命中）
class LlamaConfig {
  final String modelPath;
  final int contextSize;
  final int gpuLayers;
  final int threads;

  const LlamaConfig({
    required this.modelPath,
    this.contextSize = 2048,
    this.gpuLayers = -1,
    this.threads = 4,
  });

  @override
  bool operator ==(Object other) =>
      other is LlamaConfig &&
      modelPath == other.modelPath &&
      contextSize == other.contextSize &&
      gpuLayers == other.gpuLayers &&
      threads == other.threads;

  @override
  int get hashCode => Object.hash(modelPath, contextSize, gpuLayers, threads);
}

/// 端侧 LLM 引擎缓存池（单例）
///
/// 不封装 Chat 操作。调用方拿到 [LlamaEngine] 后自行 `createChat()` 管理 session。
///
/// 使用方式：
/// ```dart
/// final engine = await LlamaService.instance.ensureReady();
/// final chat = await engine.createChat();
/// chat.addSystem('...');
/// ```
class LlamaService {
  static final LlamaService instance = LlamaService._();

  LlamaService._();

  // key = LlamaConfig, value = 正在/已经加载的 Future
  // 用 Future 而非 LlamaEngine —— 同 config 并发调用自动排队
  final Map<LlamaConfig, Future<LlamaEngine>> _pool = {};

  /// 缓存池大小（仅供调试）
  int get poolSize => _pool.length;

  // ================================================================
  // 三层 API
  // ================================================================

  /// 默认模型 + 默认配置（99% 的使用场景）
  ///
  /// 使用 [AppConstants.defaultModelPath]，搭配默认 contextSize / gpuLayers / threads。
  Future<LlamaEngine> ensureReady() async {
    return ensureReadyWithModel(AppConstants.defaultModelPath);
  }

  /// 指定模型路径（配置用默认值）
  ///
  /// [modelPath] 模型文件的绝对路径。
  Future<LlamaEngine> ensureReadyWithModel(String modelPath) async {
    return ensureReadyWithConfig(LlamaConfig(
      modelPath: modelPath,
      contextSize: AppConstants.modelContextSize,
      gpuLayers: AppConstants.modelGpuLayers,
      threads: AppConstants.modelThreads,
    ));
  }

  /// 完全自定义配置
  ///
  /// 不同 [LlamaConfig] 生成不同缓存条目。
  /// [config] 的四个字段全参与等值比较决定缓存命中。
  Future<LlamaEngine> ensureReadyWithConfig(LlamaConfig config) async {
    // 命中缓存
    if (_pool.containsKey(config)) {
      return _pool[config]!;
    }

    // 首次加载
    final future = _loadEngine(config);
    _pool[config] = future;

    try {
      final engine = await future;
      debugPrint('[LlamaService] 引擎缓存命中: ${config.modelPath}');
      return engine;
    } catch (e) {
      _pool.remove(config); // 失败不缓存，允许重试
      rethrow;
    }
  }

  /// 释放所有缓存的引擎
  void dispose() {
    debugPrint('[LlamaService] 正在释放 ${_pool.length} 个引擎...');
    for (final entry in _pool.entries) {
      entry.value.then((engine) => engine.dispose()).catchError((_) {});
    }
    _pool.clear();
    debugPrint('[LlamaService] 引擎已释放');
  }

  // ================================================================
  // Token 估算工具（保留）
  // ================================================================

  /// 通用 token 估算工具（静态方法）
  ///
  /// 中文 CJK 字符 ≈ 1.5 tokens，其他字符 ≈ 0.25 tokens。
  static int estimateTokens(String text) {
    int chineseCount = 0;
    int otherCount = 0;
    for (final char in text.runes) {
      if ((char >= 0x4E00 && char <= 0x9FFF) ||
          (char >= 0x3400 && char <= 0x4DBF) ||
          (char >= 0x3000 && char <= 0x303F)) {
        chineseCount++;
      } else {
        otherCount++;
      }
    }
    return (chineseCount * 1.5 + otherCount * 0.25).ceil();
  }

  // ================================================================
  // 私有
  // ================================================================

  /// 解析平台对应的 native library 路径
  String _resolveLibraryPath() {
    if (Platform.isMacOS) {
      final exe = File(Platform.resolvedExecutable);
      return '${exe.parent.parent.path}/Frameworks/libllama.dylib';
    }
    if (Platform.isAndroid) {
      return 'libllama.so'; // Android .so 由 linker 加载
    }
    throw UnsupportedError('${Platform.operatingSystem} 暂不支持 LlamaService');
  }

  /// 底层引擎加载（平台感知）
  Future<LlamaEngine> _loadEngine(LlamaConfig config) async {
    debugPrint('[LlamaService] 正在加载引擎: ${config.modelPath}');

    try {
      LlamaEngine engine;

      if (Platform.isIOS) {
        // iOS: dylib 已嵌入 xcframework，用 spawnFromProcess
        engine = await LlamaEngine.spawnFromProcess(
          modelParams: ModelParams(
            path: config.modelPath,
            gpuLayers: config.gpuLayers,
          ),
          contextParams: ContextParams(
            nCtx: config.contextSize,
            nThreads: config.threads,
            typeK: KvCacheType.q8_0,
            typeV: KvCacheType.q8_0,
          ),
        );
      } else {
        // macOS / Android: 指定 dylib 路径
        engine = await LlamaEngine.spawn(
          libraryPath: _resolveLibraryPath(),
          modelParams: ModelParams(
            path: config.modelPath,
            gpuLayers: config.gpuLayers,
          ),
          contextParams: ContextParams(
            nCtx: config.contextSize,
            nThreads: config.threads,
            typeK: KvCacheType.q8_0,
            typeV: KvCacheType.q8_0,
          ),
        );
      }

      debugPrint('[LlamaService] 引擎启动完成');
      if (engine.hasAccelerator) {
        debugPrint('[LlamaService] 加速器: ${engine.primaryAcceleratorName}');
      }

      return engine;
    } catch (e, stack) {
      debugPrint('[LlamaService] 引擎加载失败: $e');
      debugPrintStack(stackTrace: stack);
      rethrow;
    }
  }
}
```

**Step 3: 静态分析验证**

```bash
flutter analyze lib/core/engine/llama_service.dart
```
Expected: No issues found.

**Step 4: Commit**

```bash
git add lib/core/engine/llama_service.dart
git commit -m "refactor(llama): rewrite as engine cache pool

- Add LlamaConfig value object (cache key: modelPath + contextSize + gpuLayers + threads)
- Three-tier API: ensureReady() / ensureReadyWithModel() / ensureReadyWithConfig()
- Platform-aware library path resolution internalized
- Cache stores Future<LlamaEngine> for concurrent call dedup
- Failure removes cache entry, allows retry
- Remove all chat wrapper methods (transferred to callers)"
```

---

### Task 2: 更新 constants.dart — 新增默认模型路径

**Files:**
- Modify: `lib/core/constants.dart`

**Step 1: 在 AppConstants 中新增 defaultModelPath**

当前 `AppConstants` 已有 `macosDevModelAbsolutePath`。新增一个通用的 `defaultModelPath` 字段，指向同一位置（未来 Day 8 模型下载后改为沙盒路径）：

```dart
// 在 AppConstants 类中新增（紧挨 macosDevModelAbsolutePath）：
/// 默认模型绝对路径（开发期硬编码，Day 8 模型下载后改为沙盒路径）
static const String defaultModelPath = macosDevModelAbsolutePath;
```

**Step 2: 静态分析验证**

```bash
flutter analyze lib/core/constants.dart
```
Expected: No issues found.

**Step 3: Commit**

```bash
git add lib/core/constants.dart
git commit -m "feat: add defaultModelPath to AppConstants"
```

---

### Task 3: 适配 SocraticPrompter — LlamaService → LlamaEngine

**Files:**
- Modify: `lib/features/chat/engine/socratic_prompter.dart`

**核心变更：**
- `LlamaService _llm` → `LlamaEngine _engine` + `EngineChat _chat`
- `isReady` 改为检查 `_engine != null`
- `llmService` getter → `engine` getter 返回 `LlamaEngine`
- `initialize()` 自己 `createChat()` + `addSystem()`
- `seedContext()` 自己 `chat.addAssistant()`
- `generateResponse()` 自己 `chat.addUser()` + `chat.generate()`
- `reset()` 自己 `clearHistory()` + 重新 `addSystem()`
- `dispose()` 不 dispose 引擎（缓存池管理），只清理自身状态
- import 变更：新增 `llama_cpp_dart` 的 EngineChat/TokerEvent/SamplerParams

**Step 1: 修改 import 区域**

将:
```dart
import 'package:socratic_ai/core/engine/llama_service.dart';
```

替换为:
```dart
import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;
import 'package:socratic_ai/core/engine/llama_service.dart';
```

**Step 2: 修改字段声明**

将:
```dart
final LlamaService _llm;
```

替换为:
```dart
final LlamaEngine _engine;
EngineChat? _chat;
```

**Step 3: 修改构造函数**

将:
```dart
SocraticPrompter(this._llm);
```

替换为:
```dart
SocraticPrompter(this._engine);
```

**Step 4: 修改 isReady**

将:
```dart
bool get isReady => _llm.isLoaded;
```

替换为:
```dart
bool get isReady => _engine != null;
```

**Step 5: 修改 llmService getter**

将:
```dart
LlamaService get llmService => _llm;
```

替换为:
```dart
LlamaEngine get engine => _engine;
```

**Step 6: 修改 initialize()**

将:
```dart
Future<bool> initialize() async {
  if (!_llm.isLoaded) return false;
  _llm.setSystemPrompt(_socraticSystemPrompt);
  return true;
}
```

替换为:
```dart
Future<bool> initialize() async {
  try {
    _chat = await _engine.createChat();
    _chat!.addSystem(_socraticSystemPrompt);
    return true;
  } catch (e) {
    debugPrint('[SocraticPrompter] 初始化失败: $e');
    return false;
  }
}
```

**Step 7: 修改 seedContext()**

将:
```dart
_llm.addAssistantMessage(welcomeMessage);
```

替换为:
```dart
_chat!.addAssistant(welcomeMessage);
```

**Step 8: 修改 generateResponse() — addUserMessage 调用**

将:
```dart
_llm.addUserMessage(formattedMessage);
```

替换为:
```dart
_chat!.addUser(formattedMessage);
```

**Step 9: 修改 generateResponse() — generate 调用（重试循环内）**

将:
```dart
await for (final token in _llm.generate(
  temperature: 0.5,
  topP: 0.85,
  maxTokens: 128,
  repeatPenalty: 1.15,
)) {
  buffer.write(token);
}
```

替换为:
```dart
await for (final event in _chat!.generate(
  sampler: SamplerParams(
    temperature: 0.5,
    topP: 0.85,
    repeatPenalty: 1.15,
  ),
  maxTokens: 128,
)) {
  if (event is TokenEvent) {
    buffer.write(event.text);
  }
}
```

**Step 10: 修改 generateResponse() — 重试提示的 addUserMessage**

将:
```dart
_llm.addUserMessage(retryHint);
```

替换为:
```dart
_chat!.addUser(retryHint);
```

**Step 11: 修改 reset()**

将:
```dart
void reset() {
  _llm.clearHistory();
  _llm.setSystemPrompt(_socraticSystemPrompt);
  _roundIndex = 0;
  _recentQuestions.clear();
  _estimatedTokens = LlamaService.estimateTokens(_socraticSystemPrompt);
}
```

替换为:
```dart
void reset() {
  _chat?.clearHistory();
  _chat?.addSystem(_socraticSystemPrompt);
  _roundIndex = 0;
  _recentQuestions.clear();
  _estimatedTokens = LlamaService.estimateTokens(_socraticSystemPrompt);
}
```

**Step 12: 修改 dispose()**

将:
```dart
void dispose() {
  _llm.dispose();
  _roundIndex = 0;
  _recentQuestions.clear();
  _estimatedTokens = 0;
}
```

替换为:
```dart
void dispose() {
  _chat?.dispose();
  _chat = null;
  // 不 dispose _engine —— 由 LlamaService 缓存池管理
  _roundIndex = 0;
  _recentQuestions.clear();
  _estimatedTokens = 0;
}
```

**Step 13: 静态分析验证**

```bash
flutter analyze lib/features/chat/engine/socratic_prompter.dart
```
Expected: No issues found.

**Step 14: Commit**

```bash
git add lib/features/chat/engine/socratic_prompter.dart
git commit -m "refactor(socratic): switch from LlamaService to LlamaEngine

- Constructor takes LlamaEngine instead of LlamaService
- Self-manage EngineChat lifecycle: createChat / addSystem / addUser / generate
- Expose engine getter for InsightService / GraphService
- Do not dispose engine in dispose() — managed by LlamaService cache pool"
```

---

### Task 4: 适配 InsightService — LlamaService → LlamaEngine

**Files:**
- Modify: `lib/features/insights/engine/insight_service.dart`

**Step 1: 修改字段和构造函数**

将:
```dart
final LlamaService _llm;
InsightService(this._llm);
```

替换为:
```dart
final LlamaEngine _engine;
InsightService(this._engine);
```

**Step 2: 修改 analyze() 中的引擎检查**

将:
```dart
final engine = _llm.engine;
if (engine == null) {
```

替换为:
```dart
// _engine 已通过构造函数传入，非空即就绪
```

并删除空检查块（`if (engine == null) { ... return empty; }`）。

将:
```dart
final chat = await engine.createChat();
```

替换为:
```dart
final chat = await _engine.createChat();
```

**Step 3: 移除不再需要的 import**

删除:
```dart
import 'package:socratic_ai/core/engine/llama_service.dart';
```

**Step 4: 静态分析验证**

```bash
flutter analyze lib/features/insights/engine/insight_service.dart
```
Expected: No issues found.

**Step 5: Commit**

```bash
git add lib/features/insights/engine/insight_service.dart
git commit -m "refactor(insight): switch InsightService from LlamaService to LlamaEngine"
```

---

### Task 5: 适配 GraphService — LlamaService → LlamaEngine

**Files:**
- Modify: `lib/features/mindmap/engine/graph_service.dart`

**Step 1: 修改字段和构造函数**

将:
```dart
final LlamaService _llm;
GraphService(this._llm);
```

替换为:
```dart
final LlamaEngine _engine;
GraphService(this._engine);
```

**Step 2: 修改 generate() 中引擎检查**

将:
```dart
final engine = _llm.engine;
if (engine == null) {
```

替换为（引擎已通过构造函数注入，check 非空即走）:
```dart
// _engine 在构造函数已传入，非空 = 就绪
```

并删除空检查块。将:
```dart
final chat = await engine.createChat();
```

替换为:
```dart
final chat = await _engine.createChat();
```

**Step 3: 移除不再需要的 import**

删除:
```dart
import 'package:socratic_ai/core/engine/llama_service.dart';
```

**Step 4: 静态分析验证**

```bash
flutter analyze lib/features/mindmap/engine/graph_service.dart
```
Expected: No issues found.

**Step 5: Commit**

```bash
git add lib/features/mindmap/engine/graph_service.dart
git commit -m "refactor(mindmap): switch GraphService from LlamaService to LlamaEngine"
```

---

### Task 6: 适配 MindMapService — 内部走缓存池

**Files:**
- Modify: `lib/features/mindmap/engine/mindmap_service.dart`

**Step 1: 修改字段、构造函数和 _generate()**

将:
```dart
class MindMapService {
  final LlamaService _llm;
  MindMapService(this._llm);

  Future<ConversationGraph> _generate(...) async {
    if (!_llm.isLoaded) {
      return const ConversationGraph();
    }
    final service = GraphService(_llm);
    return await service.generate(topic, messages);
  }
}
```

替换为:
```dart
class MindMapService {
  MindMapService();

  Future<ConversationGraph> _generate(
    String topic,
    List<ChatMessage> messages,
  ) async {
    try {
      final engine = await LlamaService.instance.ensureReady();
      final service = GraphService(engine);
      return await service.generate(topic, messages);
    } catch (e) {
      debugPrint('[MindMapService] 获取引擎失败: $e');
      return const ConversationGraph();
    }
  }
}
```

**Step 2: 添加 debugPrint import（如尚未有）**

file 已有 `import 'package:flutter/material.dart';` 包含 `debugPrint`，无需额外导入。

**Step 3: 移除不再需要的 constructor 参数**

确认 import 中 `LlamaService` 仍然需要（因为 `LlamaService.instance.ensureReady()`）。

**Step 4: 静态分析验证**

```bash
flutter analyze lib/features/mindmap/engine/mindmap_service.dart
```
Expected: No issues found.

**Step 5: Commit**

```bash
git add lib/features/mindmap/engine/mindmap_service.dart
git commit -m "refactor(mindmap): MindMapService uses cache pool internally

- Remove LlamaService constructor parameter
- Lazily fetch engine from LlamaService.instance.ensureReady()"
```

---

### Task 7: 适配 ChatProvider — 简化 loadModel

**Files:**
- Modify: `lib/features/chat/providers/chat_provider.dart`

**Step 1: 修改 loadModel()**

将:
```dart
Future<void> loadModel() async {
  _isModelLoading = true;
  notifyListeners();

  try {
    final executable = File(Platform.resolvedExecutable);
    final bundleContents = executable.parent.parent;
    final libPath = '${bundleContents.path}/Frameworks/libllama.dylib';
    final modelPath = AppConstants.macosDevModelAbsolutePath;

    final llm = LlamaService.instance;
    await llm.loadModel(
      modelPath: modelPath,
      libraryPath: libPath,
      contextSize: AppConstants.modelContextSize,
      gpuLayers: AppConstants.modelGpuLayers,
      threads: AppConstants.modelThreads,
    );

    final engine = SocraticPrompter(llm);
    await engine.initialize();
    _engine = engine;
  } catch (e) {
    debugPrint('[ChatProvider] 模型加载失败，将使用 Mock 回复: $e');
    _modelError = e.toString();
  } finally {
    _isModelLoading = false;
    notifyListeners();
  }
}
```

替换为:
```dart
Future<void> loadModel() async {
  _isModelLoading = true;
  notifyListeners();

  try {
    final llmEngine = await LlamaService.instance.ensureReady();
    final engine = SocraticPrompter(llmEngine);
    await engine.initialize();
    _engine = engine;
  } catch (e) {
    debugPrint('[ChatProvider] 模型加载失败，将使用 Mock 回复: $e');
    _modelError = e.toString();
  } finally {
    _isModelLoading = false;
    notifyListeners();
  }
}
```

**Step 2: 修改 endConversation() — InsightService 参数**

将:
```dart
final service = InsightService(engine.llmService);
```

替换为:
```dart
final service = InsightService(engine.engine);
```

**Step 3: 移除不再需要的 import**

删除:
```dart
import 'dart:io';
```

**Step 4: 静态分析验证**

```bash
flutter analyze lib/features/chat/providers/chat_provider.dart
```
Expected: No issues found (可能有一行 info: prefer_initializing_formals，是项目约定允许的)。

**Step 5: Commit**

```bash
git add lib/features/chat/providers/chat_provider.dart
git commit -m "refactor(chat): simplify ChatProvider.loadModel via cache pool

- Remove hardcoded path resolution (now in LlamaService._resolveLibraryPath)
- One-liner: await LlamaService.instance.ensureReady()
- Update InsightService constructor call to pass LlamaEngine"
```

---

### Task 8: 适配 InsightsPage — 移除 LlamaService 直接引用

**Files:**
- Modify: `lib/features/insights/insights_page.dart`

**Step 1: 修改 _openMindMap() 中的 MindMapService 调用**

将:
```dart
MindMapService(LlamaService.instance).openMindMap(context, widget.topic, messages);
```

替换为:
```dart
MindMapService().openMindMap(context, widget.topic, messages);
```

**Step 2: 移除不再需要的 import**

删除:
```dart
import 'package:socratic_ai/core/engine/llama_service.dart';
```

**Step 3: 静态分析验证**

```bash
flutter analyze lib/features/insights/insights_page.dart
```
Expected: No issues found.

**Step 4: Commit**

```bash
git add lib/features/insights/insights_page.dart
git commit -m "refactor(insights): remove LlamaService direct reference from InsightsPage"
```

---

### Task 9: 全项目静态分析 + 编译验证

**Step 1: 全项目静态分析**

```bash
flutter analyze lib/
```
Expected: 0 new issues（保留之前就存在的 1 个 info: prefer_initializing_formals）。

**Step 2: 确认无残留 LlamaService 旧 API 引用**

```bash
grep -rn "loadModel\|setSystemPrompt\|addUserMessage\|addAssistantMessage\|_ensureChat" lib/ --include="*.dart" | grep -v llama_service.dart | grep -v ".bak" | grep -v ".md"
```
Expected: 无输出（`SocraticPrompter` 里调的是 `chat.addSystem/addUser/addAssistant`，不是 LlamaService 的旧方法）。

```bash
grep -rn "\.llmService\b" lib/ --include="*.dart"
```
Expected: 无输出（旧的 `llmService` getter 已改为 `engine`）。

```bash
grep -rn "LlamaService.instance" lib/ --include="*.dart" | grep -v ".bak" | grep -v ".md"
```
Expected: 仅 `llama_service.dart`（自身定义）、`chat_provider.dart`（ensureReady）、`mindmap_service.dart`（ensureReady）三处。

**Step 3: 运行现有测试（跳过 flutter_tester 问题，用 dart test）**

```bash
flutter test test/core/models/chat_models_graph_test.dart 2>&1 || \
  /Users/superjie-mac/flutter/bin/cache/dart-sdk/bin/dart test test/core/models/chat_models_graph_test.dart -p vm
```

```bash
/Users/superjie-mac/flutter/bin/cache/dart-sdk/bin/dart test test/features/mindmap/layout/force_directed_test.dart -p vm
```
Expected: All tests pass.

**Step 4: 删除备份文件**

```bash
rm lib/core/engine/llama_service.dart.bak
```

**Step 5: Commit**

```bash
git add -A
git commit -m "chore: clean up backup file and final verification"
```
