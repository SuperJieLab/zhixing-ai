# LlamaService 重构设计

## 背景

当前 `LlamaService` 混了两个职责:
1. **引擎管理** — 加载/释放 LlamaEngine(重)
2. **Chat 会话代理** — 封装 setSystemPrompt / addUserMessage / generate 等操作(薄)

问题:
- ChatProvider 每次创建都调 loadModel()，依赖 `_isLoaded` 守卫防重复
- 业务层(ChatProvider)需要算 libraryPath、传 contextSize 等配置
- InsightsPage 通过 `LlamaService.instance` 直接拿全局单例,绕过了依赖链
- Chat 封装没有实际抽象价值(本质上是一行转发)

## 设计目标

1. **LlamaService 退化为纯引擎缓存池** — 只管引擎生命周期,不封装 chat
2. **配置内聚** — libraryPath、平台判断、默认参数全在 LlamaService 内部
3. **调用方简化** — 只需 `await LlamaService.instance.ensureReady()`
4. **按需扩展** — 同模型不同配置自动生成不同实例,不同模型各自缓存

---

## 核心设计

### LlamaConfig — 缓存 key

值对象,四字段全参与等值比较:

```dart
class LlamaConfig {
  final String modelPath;
  final int contextSize;   // default 2048
  final int gpuLayers;     // default -1
  final int threads;       // default 4

  // == / hashCode: 四字段一致 = 命中缓存
}
```

### LlamaService — 引擎缓存池

```dart
class LlamaService {
  static final LlamaService instance = LlamaService._();

  // pool 存 Future<LlamaEngine>, 不是 LlamaEngine
  // 同 config 并发调用自动排队共享一个 Future
  final Map<LlamaConfig, Future<LlamaEngine>> _pool = {};

  // ── 三层 API ──

  /// 默认模型 + 默认配置(99% 的使用场景)
  Future<LlamaEngine> ensureReady();

  /// 指定模型路径(配置用默认)
  Future<LlamaEngine> ensureReadyWithModel(String modelPath);

  /// 完全自定义
  Future<LlamaEngine> ensureReadyWithConfig(LlamaConfig config);

  // 平台路径内聚
  String _resolveLibraryPath();   // macOS / Android / iOS
  Future<LlamaEngine> _loadEngine(LlamaConfig config);

  // 清池释放
  void dispose();

  // 工具
  static int estimateTokens(String text);  // 保留
}
```

### 并发策略

池里存 `Future<LlamaEngine>` 而非 `LlamaEngine`:
- 首次调用: 创建 Future,放入池,开始加载 → 15s 后完成
- 并发调用(同 config): 返回同一个 Future → 共享等待

### 失败处理

加载失败 → 从池移除 → 抛异常。调用方可再次调 `ensureReady()` 重试。
不做内部自动重试——模型加载失败极少是瞬态的。

### Chat 会话

LlamaService 不再持有任何 chat session。调用方拿到 `LlamaEngine` 后自行 `engine.createChat()`。

---

## 调用方改动

### 之前 vs 之后

```dart
// ── ChatProvider.loadModel() ──
// 之前: 5 行算路径 + 5 个参数
final executable = File(Platform.resolvedExecutable);
final bundleContents = executable.parent.parent;
final libPath = '${bundleContents.path}/Frameworks/libllama.dylib';
final modelPath = AppConstants.macosDevModelAbsolutePath;
final llm = LlamaService.instance;
await llm.loadModel(modelPath: modelPath, libraryPath: libPath, ...);
final engine = SocraticPrompter(llm);

// 之后: 一行
final llmEngine = await LlamaService.instance.ensureReady();
final engine = SocraticPrompter(llmEngine);
```

```dart
// ── SocraticPrompter ──
// 之前: SocraticPrompter(LlamaService llm)
//       调 _llm.setSystemPrompt() / addUserMessage() / generate()
// 之后: SocraticPrompter(LlamaEngine engine)
//       自己 engine.createChat() 管 session
//       暴露 LlamaEngine get engine → 给 InsightService/GraphService
```

```dart
// ── InsightService ──
// 之前: InsightService(LlamaService _llm)  →  _llm.engine.createChat()
// 之后: InsightService(LlamaEngine _engine)  →  _engine.createChat()
```

```dart
// ── GraphService ──
// 之前: GraphService(LlamaService _llm)  →  _llm.engine.createChat()
// 之后: GraphService(LlamaEngine _engine)  →  _engine.createChat()
```

```dart
// ── MindMapService ──
// 之前: MindMapService(LlamaService.instance).openMindMap(...)
// 之后: MindMapService().openMindMap(...)
//      内部 await LlamaService.instance.ensureReady()
```

```dart
// ── InsightsPage ──
// 之前: MindMapService(LlamaService.instance).openMindMap(...)
// 之后: MindMapService().openMindMap(...)
```

### main.dart — 无改动

LlamaService 是单例自管理,不需要在 Provider 树注册。

### ChatProvider — 不需要传 llmService

`ChatProvider` 不再需要暴露 `llmService` getter——下游(MindMapService)自己走缓存池。

---

## 涉及文件

| 文件 | 操作 |
|------|------|
| `lib/core/engine/llama_service.dart` | 重写 |
| `lib/core/constants.dart` | 新增 `defaultModelPath`(或保留 AppConstants) |
| `lib/features/chat/engine/socratic_prompter.dart` | 换参数类型 LlamaService → LlamaEngine |
| `lib/features/chat/providers/chat_provider.dart` | 调用方简化 |
| `lib/features/insights/engine/insight_service.dart` | 换参数类型 |
| `lib/features/mindmap/engine/graph_service.dart` | 换参数类型 |
| `lib/features/mindmap/engine/mindmap_service.dart` | 内部走缓存池 |
| `lib/features/insights/insights_page.dart` | 移除 LlamaService 直接引用 |

---

## 缓存池行为

| 场景 | 行为 |
|------|------|
| 首次 ensureReady() | 加载 15s,缓存 |
| 第二次 ensureReady() | 命中缓存,毫秒返回 |
| 换模型 ensureReadyWithModel('b.gguf') | 新 config→加载 15s,独立缓存 |
| 同模型不同 contextSize | 新 config→加载 15s,独立缓存 |
| 并发调用(同 config) | 排队共享一个 Future |
| 加载失败 | 移除 + 抛异常,下次重试 |
