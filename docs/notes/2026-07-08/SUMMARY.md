# 2026-07-08 工作总结

## LlamaService 架构重构

### 问题发现

Day 6 开发中涉及 InsightsPage 需调用 LlamaService，触发对单例模式的重新审视。核心矛盾：

1. `LlamaService.loadModel()` 接受个性化配置参数，但单例使其「先到先得」
2. `ChatPage.build()` 每次创建 ChatProvider 都调用 `loadModel()`，依赖 `_isLoaded` 守卫防重复
3. LlamaService 混了两层职责：引擎管理（重）+ Chat 封装（薄，本质是 `_chat!.xxx()` 一行转发）
4. 业务层（ChatProvider）在做基础设施的活：算 libraryPath、传 contextSize

### 重构方向

通过 Brainstorming 确认：LlamaService 退化为纯引擎缓存池，Chat 操作全部剥离给业务方。

核心设计：
- 缓存池 key = LlamaConfig 值对象（modelPath + contextSize + gpuLayers + threads）
- 三层 API：ensureReady() / ensureReadyWithModel() / ensureReadyWithConfig()
- 池里存 Future<LlamaEngine>（并发排队）
- 失败不缓存（允许重试）
- 平台路径内聚到 LlamaService 内部
- Chat 操作不封装（各自直接面对 EngineChat）

### 实施

9 个 Task，9 次 commit，8 个文件改动：
- llama_service.dart：重写（+LlamaConfig、缓存池、平台路径内聚）
- socratic_prompter.dart：LlamaService → LlamaEngine，自管 EngineChat
- insight_service.dart / graph_service.dart：换参数类型
- mindmap_service.dart：内部走缓存池
- chat_provider.dart：-40 行（路径拼装 → 1 行 ensureReady()）
- insights_page.dart：移除 LlamaService 直接引用

验证：全项目 analyze 仅 1 已有 info，0 残留旧 API。

### 深度笔记

详见 `LlamaService-架构演进.md`（完整的发现→设计→实施过程）

### 下一步

回到 Day 6 剩余任务：测试 + 全链路验证（Task 9-10），然后进入 Day 7 错误覆盖
