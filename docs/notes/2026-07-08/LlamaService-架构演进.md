# LlamaService 架构演进

## 起点：一个设计矛盾

Day 6 思维图谱开发过程中，发现 `InsightsPage` 需要调 `LlamaService.instance` 来生成图谱。这触发了对全局单例模式的审视。

回顾现有代码，`ChatProvider.loadModel()` 是这样写的：

```dart
final llm = LlamaService.instance;
await llm.loadModel(
  modelPath: modelPath,
  libraryPath: libPath,
  contextSize: AppConstants.modelContextSize,
  gpuLayers: AppConstants.modelGpuLayers,
  threads: AppConstants.modelThreads,
);
```

而 `loadModel()` 内部第一行就是 `if (_isLoaded || _isLoading) return;`。

当时的设计存在两个矛盾：
1. `loadModel()` 接受个性化配置参数（路径、contextSize、gpuLayers），但单例让它变成「先到先得」
2. `ChatPage.build()` 每次创建 ChatProvider 都会调 `loadModel()`，依赖守卫防重复

换一个角度来看，这里的核心问题是 **LlamaService 混淆了两层职责**：

```
LlamaService
  ├── 引擎管理（重）  — loadModel / dispose / 平台判断
  └── Chat 封装（薄） — setSystemPrompt / addUserMessage / generate
```

Chat 封装本质上是 `_chat!` 的一行转发：

```dart
void setSystemPrompt(String prompt) {
  _ensureChat();
  _chat!.addSystem(prompt);  // 就是一行转发
}
```

没有抽象价值，却让 LlamaService 需要同时维护 `_engine` 和 `_chat` 两个状态。

## 诊断：loadModel 放错了位置

进一步分析发现 `loadModel()` 不应该是 ChatProvider 的职责。ChatProvider 是一个业务层组件，但它：
1. 用 `Platform.resolvedExecutable` 计算 libraryPath
2. 拼接 dylib 绝对路径
3. 传递 contextSize / gpuLayers / threads

这些都是基础设施层的工作。正确的做法是：**模型加载上移到 App 层或框架层，ChatProvider 只管「引擎就绪了吗？给我用」。**

## 设计过程

Brainstorming 中依次确认了以下决策：

### 1. 缓存池存 LlamaEngine，不存 LlamaService

引擎（几 GB 内存）才是重的，chat session（只是个上下文窗口）是轻的。缓存引擎，chat 各自创建。

### 2. 三层 API

```
ensureReady()                         → 默认模型 + 默认配置
ensureReadyWithModel('path.gguf')     → 换模型
ensureReadyWithConfig(LlamaConfig)    → 完全自定义
```

99% 的场景只调无参版本。缓存 key 是 `LlamaConfig` 值对象（modelPath + contextSize + gpuLayers + threads 四字段全参与等值比较）。

### 3. 平台路径内聚到 LlamaService

```dart
String _resolveLibraryPath() {
  if (Platform.isMacOS) { /* 从 App Bundle 找 dylib */ }
  if (Platform.isAndroid) { return 'libllama.so'; }
  throw UnsupportedError('...');
}
```

调用方只用 `ensureReady()`，不感知平台差异。

### 4. 并发排队而非报错

缓存池里存的是 `Future<LlamaEngine>` 而非 `LlamaEngine`。同 config 的并发调用自动共享同一个 Future，排队等待。

### 5. 失败不缓存

```dart
try {
  final engine = await future;
  return engine;
} catch (e) {
  _pool.remove(config);  // 失败移除
  rethrow;               // 调用方可重试
}
```

模型加载失败极少是瞬态的，不做内部自动重试。

### 6. 不封装 Chat 操作

曾经考虑过：`addSystem` / `addUser` / `generate` 这些方法是不是放回 LlamaService？结论是不放——它们太薄了，`EngineChat` 本身已经是干净的 API。而且 SocraticPrompter、InsightService、GraphService 三个业务各自管理 chat 生命周期，封装反而增加耦合。

## 实施结果

9 个 Task，9 次 commit，8 个文件改动。

### 调用方对比

```dart
// ── 之前 ──
final executable = File(Platform.resolvedExecutable);
final bundleContents = executable.parent.parent;
final libPath = '${bundleContents.path}/Frameworks/libllama.dylib';
final modelPath = AppConstants.macosDevModelAbsolutePath;
final llm = LlamaService.instance;
await llm.loadModel(
  modelPath: modelPath, libraryPath: libPath,
  contextSize: ..., gpuLayers: ..., threads: ...,
);
final engine = SocraticPrompter(llm);

// ── 之后 ──
final llmEngine = await LlamaService.instance.ensureReady();
final engine = SocraticPrompter(llmEngine);
```

ChatProvider 从 40 行路径+参数拼装变成 1 行 `ensureReady()`。

### 依赖链清理

```
之前：
InsightsPage → LlamaService.instance (绕过 ChatProvider 直接拿全局单例)
ChatProvider  → LlamaService.instance.loadModel(...) (算路径、传配置)

之后：
InsightsPage → MindMapService() → LlamaService.instance.ensureReady()
ChatProvider  → LlamaService.instance.ensureReady()
```

### 缓存池行为

| 场景 | 行为 |
|---|---|
| 首次进入对话 | `ensureReady()` → 加载 15s → 缓存 |
| 再次进入对话 | 命中缓存，毫秒返回 |
| 同一模型不同 contextSize | 新 config → 新实例 → 独立缓存 |
| 并发调用（同 config） | 排队共享一个 Future，只加载一次 |
| 加载失败 | 从池移除，下次调用重试 |

## 总结

这次重构的核心教训：**当单例 + 带配置参数的加载方法同时出现时，一定有一个放错了位置。** 要么配置上移到更底层（框架/平台层），要么加载逻辑从业务层剥离。我们选择了前者——把平台判断和路径拼装塞进 LlamaService，让它成为一个「自给自足」的缓存池，业务方只需问一句「就绪了吗」。
