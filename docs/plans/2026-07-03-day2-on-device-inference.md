# Day 2 — 端侧推理接入 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Dart → llama.cpp → Metal 推理链路跑通，macOS 上能够加载模型并完成首次对话

**Architecture:** 使用 `llama_cpp_dart` v0.9.0-dev.9 的 Worker Isolate API — `LlamaEngine.spawn()` 在独立 isolate 中启动推理引擎，`EngineChat` 管理多轮对话历史。macOS 开发用预编译 `.dylib`，iOS 发布用 `.xcframework`

**Tech Stack:** Flutter 3.x + llama_cpp_dart v0.9.0-dev.9 + Qwen 2.5 0.5B Q4_K_M GGUF + Metal (Apple Silicon)

**注意：** PRD 中提到的 `dart_llama` 包不存在，实际为 `llama_cpp_dart`。v0.9.0-dev.9 提供预编译原生库，无需从源码编译 llama.cpp

---

### Task 1: 添加 llama_cpp_dart 依赖

**Files:**
- Modify: `pubspec.yaml`

**背景知识：**
- `llama_cpp_dart` 是 dart_llama 的正确包名
- v0.9.0-dev.9 是预发布版，API 建议用 `^0.9.0-dev.9` 语法锁定
- 包大小约 2MB（纯 Dart 代码，原生库需单独下载）

**Step 1: 在 pubspec.yaml 加依赖**

```yaml
dependencies:
  llama_cpp_dart: ^0.9.0-dev.9
```

**Step 2: 运行 flutter pub get**

```bash
cd /Users/superjie-mac/projects/socratic-ai && flutter pub get
```

Expected: `Got dependencies!` 无报错

**Step 3: 验证静态分析**

```bash
flutter analyze
```

Expected: `No issues found!` 或仅有预先存在的 info 级别提示

**Step 4: 提交**

```bash
git add pubspec.yaml pubspec.lock
git commit -m "chore: add llama_cpp_dart v0.9.0-dev.9 for on-device inference"
```

---

### Task 2: 下载 macOS 原生库

**Files:**
- Create: `native/macos/` (目录)
- Update: `.gitignore` — 排除 large binary

**背景知识：**
- `llama_cpp_dart` 的 GitHub Releases 提供预编译 macOS `.dylib` 文件
- v0.9.0-dev.9 release 包含 `macos-libllama.zip`（约 10.5 MB）
- 解压后有 3 个文件：`libllama.dylib` (主库)、`libggml*.dylib` (后端)、`libmtmd.dylib` (多模态)
- 这些是 Universal Binary（arm64 + x86_64），在你的 M1 Mac 上自动用 arm64 slice

**Step 1: 创建目录并下载**

```bash
mkdir -p /Users/superjie-mac/projects/socratic-ai/native/macos
curl -L -o /tmp/macos-libllama.zip \
  https://github.com/netdur/llama_cpp_dart/releases/download/v0.9.0-dev.9/macos-libllama.zip
```

**Step 2: 解压**

```bash
unzip -o /tmp/macos-libllama.zip -d /Users/superjie-mac/projects/socratic-ai/native/macos/
```

**Step 3: 验证文件结构**

```bash
ls -la /Users/superjie-mac/projects/socratic-ai/native/macos/
file /Users/superjie-mac/projects/socratic-ai/native/macos/libllama.dylib
```

Expected: `Mach-O 64-bit dynamically linked shared library arm64` (至少包含 arm64 slice)

**Step 4: 更新 .gitignore—排除大文件**

在 `.gitignore` 末尾添加（Native libraries are too large for git, downloaded during setup）:

```
native/
```

注意：这不会影响已提交的文件，只是从此以后 native/ 目录不被 git 追踪

**Step 5: 提交 .gitignore 更新**

```bash
git add .gitignore
git commit -m "chore: exclude native/ libraries from git tracking"
```

---

### Task 3: 编写 LlamaInferenceService（TDD）

**Files:**
- Create: `lib/features/inference/services/llama_inference_service.dart`
- Create: `lib/features/inference/models/inference_config.dart`
- Create: `test/features/inference/services/llama_inference_service_test.dart`

**架构思路：**
- Service 封装 `LlamaEngine`，对外暴露最简接口：`loadModel()` / `chat()` / `dispose()`
- `InferenceConfig` 分离平台相关路径（macOS `.dylib` vs iOS `spawnFromProcess`）
- `LLamaInferenceService` 不继承 `ChangeNotifier`——推理结果通过 `Stream<String>` 流式输出
- 所有 llama.cpp 细节（ModelParams, ContextParams, SamplerParams）封装在 service 内部，调用方不感知

**Step 1: 创建目录**

```bash
mkdir -p /Users/superjie-mac/projects/socratic-ai/lib/features/inference/services
mkdir -p /Users/superjie-mac/projects/socratic-ai/lib/features/inference/models
mkdir -p /Users/superjie-mac/projects/socratic-ai/test/features/inference/services
```

**Step 2: 写 InferenceConfig 模型**

文件：`lib/features/inference/models/inference_config.dart`

```dart
/// 推理引擎的平台相关配置
///
/// 负责区分 macOS 开发环境（loadLibrary + .dylib）和 iOS 发布环境（spawnFromProcess）。
/// 不包含模型路径——模型路径由调用方在 loadModel() 时传入。
class InferenceConfig {
  /// macOS 开发：dylib 文件的绝对路径
  final String? libraryPath;

  /// iOS 发布：使用已链接到 App 进程的 llama.cpp 符号
  final bool useProcessSymbols;

  /// 模型文件所在的目录（可选，默认为 native/models/）
  final String modelDirectory;

  const InferenceConfig({
    this.libraryPath,
    this.useProcessSymbols = false,
    this.modelDirectory = 'native/models',
  });

  /// macOS 开发环境配置
  ///
  /// 使用预编译的 .dylib 文件。
  /// [libraryPath] 指向 libllama.dylib 的绝对路径，
  /// 例如 'native/macos/libllama.dylib'。
  factory InferenceConfig.macOS(String libraryPath) {
    return InferenceConfig(
      libraryPath: libraryPath,
      useProcessSymbols: false,
    );
  }

  /// iOS 发布环境配置
  ///
  /// 使用 .xcframework 中已链接的 llama.cpp 符号，
  /// 不需要指定 libraryPath。
  factory InferenceConfig.iOS() {
    return InferenceConfig(
      useProcessSymbols: true,
    );
  }
}
```

**Step 3: 写 failing test**

文件：`test/features/inference/services/llama_inference_service_test.dart`

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:socratic_ai/features/inference/models/inference_config.dart';
import 'package:socratic_ai/features/inference/services/llama_inference_service.dart';

void main() {
  group('LLamaInferenceService — 状态流转', () {
    late InferenceConfig config;

    setUp(() {
      // 使用假的 libraryPath（单元测试不实际加载模型）
      config = InferenceConfig.macOS('/fake/path/libllama.dylib');
    });

    test('初始状态：未加载', () {
      final service = LLamaInferenceService(config: config);

      // isLoaded 默认 false
      expect(service.isLoaded, isFalse);
    });

    test('loadModel 后调用 chat 会报错（模型路径无效时抛异常）', () async {
      final service = LLamaInferenceService(config: config);

      // loadModel 传入不存在的文件路径 → 应该抛异常
      expect(
        () => service.loadModel(modelPath: '/nonexistent/model.gguf'),
        throwsA(isA<Exception>()),
      );
    });

    test('未加载模型时调用 chat 抛 StateError', () async {
      final service = LLamaInferenceService(config: config);

      expect(
        () => service.chat(userMessage: 'hello'),
        throwsA(isA<StateError>()),
      );
    });

    test('dispose 后 isLoaded 变 false', () async {
      final service = LLamaInferenceService(config: config);

      // dispose 一个未加载的 service 不应报错（幂等性）
      await service.dispose();
      expect(service.isLoaded, isFalse);
    });
  });

  group('LLamaInferenceService — 平台配置', () {
    test('macOS 配置使用 spawn + libraryPath', () {
      final config = InferenceConfig.macOS('/path/to/libllama.dylib');

      expect(config.useProcessSymbols, isFalse);
      expect(config.libraryPath, '/path/to/libllama.dylib');
    });

    test('iOS 配置使用 spawnFromProcess', () {
      final config = InferenceConfig.iOS();

      expect(config.useProcessSymbols, isTrue);
      expect(config.libraryPath, isNull);
    });
  });
}
```

**Step 4: 运行测试验证失败**

```bash
flutter test test/features/inference/services/llama_inference_service_test.dart
```

Expected: `FAIL` — `LLamaInferenceService` 类不存在

**Step 5: 实现 LLamaInferenceService**

文件：`lib/features/inference/services/llama_inference_service.dart`

```dart
import 'dart:async';
import 'dart:io';

import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import 'package:socratic_ai/features/inference/models/inference_config.dart';

/// 端侧推理服务的封装类
///
/// 职责：
/// - 加载 GGUF 模型文件到 LlamaEngine worker isolate
/// - 提供 chat() 方法进行对话式推理（流式返回 token）
/// - 管理引擎生命周期（load → chat → dispose）
///
/// 使用方式：
/// ```dart
/// final service = LLamaInferenceService(config: InferenceConfig.macOS(...));
/// await service.loadModel(modelPath: '...');
/// await for (final token in service.chat(userMessage: '你好')) {
///   print(token); // 逐 token 输出
/// }
/// await service.dispose();
/// ```
class LLamaInferenceService {
  final InferenceConfig config;

  /// llama.cpp 推理引擎（在独立 isolate 中运行，不阻塞 UI 线程）
  LlamaEngine? _engine;

  /// 当前活跃的聊天对话句柄
  EngineChat? _chat;

  LLamaInferenceService({required this.config});

  /// 模型是否已加载到内存
  bool get isLoaded => _engine != null;

  /// 加载 GGUF 模型文件
  ///
  /// 在独立 isolate 中启动 llama.cpp 推理引擎。
  /// [modelPath] 是 GGUF 文件的绝对路径。
  ///
  /// 抛出 [Exception]：
  /// - 文件不存在
  /// - 模型格式不正确
  /// - 内存不足
  Future<void> loadModel({required String modelPath}) async {
    // 验证文件存在（提前失败，给出明确错误信息）
    final file = File(modelPath);
    if (!await file.exists()) {
      throw Exception('模型文件不存在: $modelPath');
    }

    // 模型参数：Qwen 2.5 0.5B 只需 ~400MB 内存
    // gpuLayers: 99 = 所有层 offload 到 Metal GPU
    final modelParams = ModelParams(
      path: modelPath,
      gpuLayers: 99,
      useMmap: true,
      useMlock: false,
    );

    // 上下文参数：2048 token 窗口（对话场景足够）
    final contextParams = ContextParams(
      nCtx: 2048,
      nBatch: 512,
      nUbatch: 256,
      nThreads: 0, // 自动选择
      nThreadsBatch: 0,
      flashAttn: FlashAttention.auto, // Metal 自动启用
      typeK: KvCacheType.q8_0, // KV cache 量化减半内存
      typeV: KvCacheType.q8_0,
      embeddings: false,
      noPerf: true,
    );

    if (config.useProcessSymbols) {
      // iOS 发布模式：使用已链接的 xcframework 符号
      _engine = await LlamaEngine.spawnFromProcess(
        modelParams: modelParams,
        contextParams: contextParams,
      );
    } else {
      // macOS 开发模式：从 .dylib 加载
      _engine = await LlamaEngine.spawn(
        libraryPath: config.libraryPath!,
        modelParams: modelParams,
        contextParams: contextParams,
      );
    }
  }

  /// 对话式推理（流式返回 token）
  ///
  /// [userMessage] 用户输入
  /// [systemPrompt] 系统提示词（可选，默认使用苏格拉底追问 prompt）
  /// [history] 历史对话消息（可选，首次对话时为空）
  ///
  /// 返回 [Stream]<String>——每个事件是一个 token 字符串。
  /// 需要先调用 [loadModel]。
  ///
  /// 抛出 [StateError]：模型尚未加载
  Stream<String> chat({
    required String userMessage,
    String systemPrompt =
        '你是一个苏格拉底式的对话伙伴。'
        '你的任务是通过提问帮助用户深入思考，而不是给出答案。'
        '每次回复只问一个问题，保持中立和开放。',
    List<Map<String, String>>? history,
  }) async* {
    if (_engine == null) {
      throw StateError('模型尚未加载，请先调用 loadModel()');
    }

    // 创建新的聊天对话（每次 chat() 调用创建新 session）
    _chat = await _engine!.createChat();

    // 注入系统提示词
    _chat!.addSystem(systemPrompt);

    // 注入历史消息（保持上下文连贯）
    if (history != null) {
      for (final msg in history) {
        final role = msg['role']!;
        final content = msg['content']!;
        if (role == 'user') {
          _chat!.addUser(content);
        } else if (role == 'assistant') {
          _chat!.addAssistant(content);
        }
      }
    }

    // 添加用户最新消息
    _chat!.addUser(userMessage);

    // 采样参数：平衡创意与一致性
    final sampler = SamplerParams(
      temperature: 0.7,
      topP: 0.9,
      topK: 40,
      repeatPenalty: 1.1,
      seed: -1, // 随机
      maxTokens: 128,
    );

    // 流式生成
    final stream = _chat!.generate(
      sampler: sampler,
      maxTokens: 128,
    );

    await for (final event in stream) {
      if (event is TokenEvent) {
        yield event.text;
      }
      // DoneEvent 会被自动处理，不需要 yield
    }

    // 对话完成后释放 EngineChat（但保留 LlamaEngine 以备下次对话）
    await _chat?.dispose();
    _chat = null;
  }

  /// 释放引擎资源
  ///
  /// 调用后 [isLoaded] 变为 false。
  /// 必须在使用完毕后调用，否则 worker isolate 会泄漏。
  Future<void> dispose() async {
    await _chat?.dispose();
    _chat = null;
    await _engine?.dispose();
    _engine = null;
  }
}
```

**Step 6: 运行测试验证通过**

```bash
flutter test test/features/inference/services/llama_inference_service_test.dart
```

Expected: `All 4 tests passed!`

**Step 7: 提交**

```bash
git add lib/features/inference/ test/features/inference/
git commit -m "feat: add LLamaInferenceService with TDD state-flow tests"
```

---

### Task 4: 下载测试用小模型

**Files:**
- Create: `native/models/` (目录，已通过 .gitignore 排除)

**背景知识：**
- Qwen 2.5 0.5B Instruct Q4_K_M：约 400MB，1.33 tok/s（M1），适合快速验证
- Qwen 系列使用 ChatML 格式，llama.cpp 从 GGUF metadata 自动检测
- 后续 Day 9 再下载 Qwen 2.5 1.5B Q4_K_M（~1GB）

**Step 1: 创建模型目录并下载**

```bash
mkdir -p /Users/superjie-mac/projects/socratic-ai/native/models
curl -L -o /Users/superjie-mac/projects/socratic-ai/native/models/qwen2.5-0.5b-instruct-q4_k_m.gguf \
  "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf"
```

Expected: 下载完成后文件大小约 350-400MB

注意：这一步可能耗时 1-5 分钟（取决于网速），建议在步骤 5 之前先触发下载

**Step 2: 验证文件**

```bash
ls -lh /Users/superjie-mac/projects/socratic-ai/native/models/qwen2.5-0.5b-instruct-q4_k_m.gguf
```

Expected: 文件大小 > 200MB

**Step 3: 提交（只需更新 .gitignore，模型文件本身已被排除）**

```bash
# .gitignore 在 Task 2 已更新，本步骤无需额外提交
```

---

### Task 5: macOS 端到端推理测试（集成测试）

**Files:**
- Create: `test/features/inference/services/llama_inference_e2e_test.dart`

**注意：** 此步骤为集成测试，需要真实模型和原生库。与 Task 3 的单元测试不同，这步**实际加载模型并推理**。如果模型未下载或原生库缺失，测试会失败。

**Step 1: 写集成测试**

文件：`test/features/inference/services/llama_inference_e2e_test.dart`

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:socratic_ai/features/inference/models/inference_config.dart';
import 'package:socratic_ai/features/inference/services/llama_inference_service.dart';

/// 端到端推理测试
///
/// 注意：此测试需要先完成 Task 2（下载原生库）和 Task 4（下载模型）。
/// 运行方式：
///   flutter test test/features/inference/services/llama_inference_e2e_test.dart
void main() {
  // 模型和原生库的绝对路径
  final projectRoot = Directory.current.path;
  final modelPath = '$projectRoot/native/models/qwen2.5-0.5b-instruct-q4_k_m.gguf';
  final libraryPath = '$projectRoot/native/macos/libllama.dylib';

  group('LLamaInferenceService — macOS 端到端推理', () {
    late LLamaInferenceService service;

    setUp(() {
      service = LLamaInferenceService(
        config: InferenceConfig.macOS(libraryPath),
      );
    });

    tearDown(() async {
      await service.dispose();
    });

    // 前置检查：模型和原生库是否存在
    test('前置条件：原生库存在', () {
      expect(File(libraryPath).existsSync(), isTrue,
          reason: '请先完成 Task 2：下载 macOS 原生库');
    });

    test('前置条件：模型文件存在', () {
      expect(File(modelPath).existsSync(), isTrue,
          reason: '请先完成 Task 4：下载测试模型');
    });

    // 核心测试：加载模型
    test('loadModel 成功加载模型，isLoaded 变 true', () async {
      // 超时设为 60 秒（大模型加载需要时间）
      await service.loadModel(modelPath: modelPath).timeout(
        const Duration(seconds: 60),
      );

      expect(service.isLoaded, isTrue);
    });

    // 核心测试：推理
    test('chat 返回合理的推理结果', () async {
      // 先加载模型
      await service.loadModel(modelPath: modelPath).timeout(
        const Duration(seconds: 60),
      );

      // 发送简单的数学问题（不需要中文模型也能回答）
      final tokens = <String>[];
      final stream = service.chat(userMessage: '1+1等于几？用中文回答');

      await for (final token in stream.timeout(const Duration(seconds: 30))) {
        tokens.add(token);
      }

      final result = tokens.join();
      print('推理结果: $result');

      // 验证：非空 + 包含有效文本
      expect(tokens, isNotEmpty);
      expect(result.length, greaterThan(2));
    });

    // 生命周期测试
    test('dispose 后 isLoaded 为 false', () async {
      await service.loadModel(modelPath: modelPath).timeout(
        const Duration(seconds: 60),
      );
      expect(service.isLoaded, isTrue);

      await service.dispose();
      expect(service.isLoaded, isFalse);
    });
  });
}
```

**Step 2: 运行集成测试**

```bash
flutter test test/features/inference/services/llama_inference_e2e_test.dart
```

Expected:
- 前置条件测试：PASS（如果原生库和模型已下载）
- loadModel 测试：PASS（模型加载成功）
- chat 测试：PASS（返回包含有效文本的推理结果）
- dispose 测试：PASS（资源释放成功）

可能失败情况：
- 模型未下载 → "请先完成 Task 4"
- 内存不足 → 调整 `nCtx` 减小窗口
- 超时 → 增大 timeout Duration

**Step 3: 提交集成测试**

```bash
git add test/features/inference/services/llama_inference_e2e_test.dart
git commit -m "test: add macOS end-to-end LLM inference test"
```

---

### Task 6: iOS xcframework 准备（部署准备，可后置）

**Files:**
- Create: `ios/llama.xcframework/` (目录，已通过 .gitignore 排除因为 Task 2 排除了 native/)

**背景知识：**
- xcframework 是 Apple 的多架构打包格式，一次编译同时支持真机（ios-arm64）和模拟器（ios-arm64-simulator）
- 实际内容约 18MB
- 后续 Day 6 联调时才会在 iOS 上实际使用
- macOS 的 `.dylib` 文件和 iOS 的 `.xcframework` 是**同一套 llama.cpp 的不同编译产物**

**注意：** 此步骤可在 Day 3-6 之间完成，当前优先级低于 Task 5（端到端验证）

**Step 1: 下载 xcframework**

```bash
curl -L -o /tmp/llama-xcframework.zip \
  https://github.com/netdur/llama_cpp_dart/releases/download/v0.9.0-dev.9/llama-xcframework.zip
unzip -o /tmp/llama-xcframework.zip -d /Users/superjie-mac/projects/socratic-ai/ios/
```

**Step 2: 验证 xcframework**

```bash
ls -la /Users/superjie-mac/projects/socratic-ai/ios/llama.xcframework/
```

Expected: 包含 `Info.plist` 和 `ios-arm64/`、`ios-arm64-simulator/` 子目录

**Step 3: 验证 .gitignore 排除**

```bash
git status --short
```

Expected: 不显示 `ios/llama.xcframework/`（说明 .gitignore 规则生效）

**Step 4: 配置 Xcode 项目**

苹果的 xcframework 需要手动在 Xcode 中 Embed & Sign：
1. 打开 `ios/Runner.xcodeproj`
2. General → Frameworks, Libraries, and Embedded Content
3. 拖入 `ios/llama.xcframework/`
4. 设置为 `Embed & Sign`

这一步无法通过命令行完成，需要你手动在 Xcode 中操作

**Step 5: 提交（无代码变更，仅确认 .gitignore）**

```bash
# xcframework 已被 .gitignore 排除，本步骤无需提交
# 后续 Day 6 联调时才会涉及 Xcode 项目文件变更
```

---

## 非功能验证

在所有 task 完成后运行：

```bash
# 全量单元测试（不含 e2e）
flutter test --exclude-tags e2e

# 静态分析
flutter analyze
```

Expected: 单元测试全部通过，静态分析零 issue

---

## 风险与降级参照

| 风险 | 概率 | 现象 | 降级策略 |
|:--|:--|:--|:--|
| v0.9.0-dev.9 某 API 不存在 | 低 | pub get 后编译报错 | 降级到 0.2.2 + 手写 isolate 管理 |
| Metal 推理 crash | 低 | macOS 上 `loadModel` 抛 SIGABRT | `gpuLayers: 0` 全 CPU 推理先验证 |
| 模型下载太慢 | 中 | curl 长时间无进度 | 用 wget 或手动浏览器下载 |
| 模型加载 OOM | 低 | Mac 内存不足 | 0.5B Q4 仅需 ~400MB，远低于你的 16GB RAM |

---

*创建时间：2026-07-03*
*参考文档：docs/demo-plan-socratic-ai.md Day 2 + docs/requirements-goals.md 第 2 章*
*API 参考：llama_cpp_dart v0.9.0-dev.9 pub.dev + GitHub Releases + 源码*
