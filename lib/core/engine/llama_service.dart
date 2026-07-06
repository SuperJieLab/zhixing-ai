import 'package:flutter/foundation.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';

/// LlamaService — 端侧 LLM 推理引擎封装
///
/// 只负责 llama.cpp 引擎生命周期和底层的 chat 操作。
/// 不包含任何业务逻辑（Prompt 模板、追问策略、去重等）。
///
/// 业务逻辑由 [SocraticPrompter] 负责，它组合 LlamaService 并实现 [DialogueEngine]。
///
/// 使用方式：
/// ```dart
/// final llm = LlamaService();
/// await llm.loadModel(modelPath: '...', libraryPath: '...');
/// llm.setSystemPrompt('你是一个助手...');
/// llm.addUserMessage('你好');
/// await for (final token in llm.generate()) {
///   print(token);
/// }
/// ```
class LlamaService {
  LlamaEngine? _engine;
  EngineChat? _chat;

  bool _isLoaded = false;
  bool _isLoading = false;

  /// 模型是否已加载并就绪
  bool get isLoaded => _isLoaded;

  /// 是否正在加载中
  bool get isLoading => _isLoading;

  /// 当前设备的硬件加速器名称（Metal / Hexagon / null = CPU）
  String? get acceleratorName => _engine?.primaryAcceleratorName;

  // ================================================================
  // 模型加载
  // ================================================================

  /// 加载 GGUF 模型并初始化推理引擎（指定 dylib 路径）。
  Future<void> loadModel({
    required String modelPath,
    required String libraryPath,
    int contextSize = 2048,
    int gpuLayers = -1,
    int threads = 4,
  }) async {
    if (_isLoaded || _isLoading) return;

    _isLoading = true;
    try {
      debugPrint('[LlamaService] 正在加载模型: $modelPath');

      _engine = await LlamaEngine.spawn(
        libraryPath: libraryPath,
        modelParams: ModelParams(
          path: modelPath,
          gpuLayers: gpuLayers,
        ),
        contextParams: ContextParams(
          nCtx: contextSize,
          nThreads: threads,
          typeK: KvCacheType.q8_0,
          typeV: KvCacheType.q8_0,
        ),
      );

      debugPrint('[LlamaService] 引擎启动完成');
      if (_engine!.hasAccelerator) {
        debugPrint('[LlamaService] 加速器: ${_engine!.primaryAcceleratorName}');
      }

      _chat = await _engine!.createChat();
      _isLoaded = true;
      debugPrint('[LlamaService] 模型加载完成');
    } catch (e, stack) {
      debugPrint('[LlamaService] 加载失败: $e');
      debugPrintStack(stackTrace: stack);
      _engine?.dispose();
      _engine = null;
      rethrow;
    } finally {
      _isLoading = false;
    }
  }

  /// 从已嵌入进程的 xcframework 加载（iOS/macOS App 打包场景）。
  Future<void> loadModelFromProcess({
    required String modelPath,
    int contextSize = 2048,
    int gpuLayers = -1,
    int threads = 4,
  }) async {
    if (_isLoaded || _isLoading) return;

    _isLoading = true;
    try {
      _engine = await LlamaEngine.spawnFromProcess(
        modelParams: ModelParams(
          path: modelPath,
          gpuLayers: gpuLayers,
        ),
        contextParams: ContextParams(
          nCtx: contextSize,
          nThreads: threads,
          typeK: KvCacheType.q8_0,
          typeV: KvCacheType.q8_0,
        ),
      );

      _chat = await _engine!.createChat();
      _isLoaded = true;
      debugPrint('[LlamaService] 模型加载完成（进程内符号）');
    } catch (e, stack) {
      debugPrint('[LlamaService] 加载失败: $e');
      debugPrintStack(stackTrace: stack);
      _engine?.dispose();
      _engine = null;
      rethrow;
    } finally {
      _isLoading = false;
    }
  }

  // ================================================================
  // Chat 操作（无状态，纯粹的消息传递）
  // ================================================================

  /// 设置系统提示词（必须在使用前调用）
  void setSystemPrompt(String prompt) {
    _ensureChat();
    _chat!.addSystem(prompt);
  }

  /// 添加一条用户消息到对话历史
  void addUserMessage(String message) {
    _ensureChat();
    _chat!.addUser(message);
  }

  /// 添加一条 assistant 消息到对话历史
  void addAssistantMessage(String message) {
    _ensureChat();
    _chat!.addAssistant(message);
  }

  /// 流式生成回复
  ///
  /// 每 yield 一个 token 字符串。
  /// 调用前需要先通过 [addUserMessage] 添加用户输入。
  Stream<String> generate({
    double temperature = 0.7,
    double topP = 0.9,
    int maxTokens = 256,
  }) async* {
    _ensureChat();
    try {
      await for (final event in _chat!.generate(
        sampler: SamplerParams(
          temperature: temperature,
          topP: topP,
        ),
        maxTokens: maxTokens,
      )) {
        if (event is TokenEvent) {
          yield event.text;
        }
      }
    } on StateError catch (e) {
      debugPrint('[LlamaService] StateError: $e');
      yield '[生成错误]';
    } catch (e, stack) {
      debugPrint('[LlamaService] generate 异常: $e');
      debugPrintStack(stackTrace: stack);
      yield '[生成错误]';
    }
  }

  /// 清空对话历史（保留系统提示词需要重新设置）
  void clearHistory() {
    _chat?.clearHistory();
  }

  /// 释放引擎及所有资源
  Future<void> dispose() async {
    debugPrint('[LlamaService] 正在释放引擎...');
    _chat = null;
    _engine?.dispose();
    _engine = null;
    _isLoaded = false;
    debugPrint('[LlamaService] 引擎已释放');
  }

  // ================================================================
  // 私有
  // ================================================================

  void _ensureChat() {
    if (_chat == null) {
      throw StateError('LlamaService 未初始化，请先调用 loadModel');
    }
  }
}
