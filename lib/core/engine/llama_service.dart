import 'dart:io';

import 'package:llama_cpp_dart/llama_cpp_dart.dart';

import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/logger.dart';

/// 模型加载配置（值对象，决定缓存命中）
class LlamaConfig {
  final String modelPath;
  final int contextSize;
  final int gpuLayers;
  final int threads;

  const LlamaConfig({
    required this.modelPath,
    this.contextSize = 4096,
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
      AppLogger.info('LlamaService', '引擎加载完成: ${config.modelPath}');
      return engine;
    } catch (e) {
      _pool.remove(config); // 失败不缓存，允许重试
      rethrow;
    }
  }

  /// 释放所有缓存的引擎
  void dispose() {
    AppLogger.info('LlamaService', '正在释放 ${_pool.length} 个引擎...');
    for (final entry in _pool.entries) {
      entry.value.then((engine) => engine.dispose()).catchError((_) {});
    }
    _pool.clear();
    AppLogger.info('LlamaService', '引擎已释放');
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
    AppLogger.info('LlamaService', '正在加载引擎: ${config.modelPath}');

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

      AppLogger.info('LlamaService', '引擎启动完成');
      if (engine.hasAccelerator) {
        AppLogger.info('LlamaService', '加速器: ${engine.primaryAcceleratorName}');
      }

      return engine;
    } catch (e, stack) {
      AppLogger.error('LlamaService', '引擎加载失败', e, stack);
      rethrow;
    }
  }
}
