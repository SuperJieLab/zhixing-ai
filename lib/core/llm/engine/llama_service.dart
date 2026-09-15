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
/// final engine = await LlamaService.instance
///     .ensureReady(modelPath: '/path/to/model.gguf', gpuLayers: 0);
/// final chat = await engine.createChat();
/// chat.addSystem('...');
/// ```
class LlamaService {
  static final LlamaService instance = LlamaService._();

  LlamaService._();

  // key = LlamaConfig, value = 正在/已经加载的 Future
  // 用 Future 而非 LlamaEngine —— 同 config 并发调用自动排队
  final Map<LlamaConfig, Future<LlamaEngine>> _pool = {};

  // ================================================================
  // 三层 API
  // ================================================================

  /// 按模型路径加载引擎（其余配置取 [AppConstants] 默认值）
  ///
  /// [modelPath] 模型文件的绝对路径，**由调用方提供**（生产是
  /// `ActiveModelManager.activeModelPath`）。引擎层不持有「当前活跃模型」
  /// 这个概念，故不再回退全局默认路径。
  /// [gpuLayers] 不传时回退 [AppConstants.localGpuLayers]（生产应传
  /// [SettingsRepository.gpuLayers]，由用户设置决定 GPU / CPU）。
  Future<LlamaEngine> ensureReady({
    required String modelPath,
    int? gpuLayers,
  }) {
    return ensureReadyWithConfig(LlamaConfig(
      modelPath: modelPath,
      contextSize: AppConstants.localContextSize,
      gpuLayers: gpuLayers ?? AppConstants.localGpuLayers,
      threads: AppConstants.localThreads,
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

  /// 释放指定配置的缓存引擎（池失效）。
  ///
  /// 供 [LlmService] 的延迟释放 / 模型切换调用：只 `engine.dispose()` 而不清池的话，
  /// 下次 `ensureReady` 会**命中缓存并返回已释放的引擎**（createChat 必炸，
  /// 且此后每次重试都命中同一条目 → 本地模式永久损坏直至重启）。
  ///
  /// [modelPath] 须与加载时一致（模型切换后须显式传旧路径，否则放跑旧条目）；
  /// [gpuLayers] 同理。
  /// 条目不存在时为幂等 no-op。配置不匹配时残留旧条目——与历史上池从无逐出
  /// 机制一致，不做全局 `dispose()`。
  Future<void> release({required String modelPath, int? gpuLayers}) async {
    final config = LlamaConfig(
      modelPath: modelPath,
      contextSize: AppConstants.localContextSize,
      gpuLayers: gpuLayers ?? AppConstants.localGpuLayers,
      threads: AppConstants.localThreads,
    );
    final future = _pool.remove(config);
    if (future == null) return;
    try {
      final engine = await future;
      engine.dispose();
      AppLogger.info('LlamaService', '引擎已释放: ${config.modelPath}');
    } catch (_) {
      // 加载本身就失败过的条目无可释放
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

  /// 是否有已加载（或加载中）的引擎——供 [LlmService.isReady] 表达端侧就绪态。
  bool get hasLoadedEngine => _pool.isNotEmpty;

  // ================================================================
  // 私有
  // ================================================================

  /// 解析平台对应的 native library 路径（macOS / Android 用；iOS 走 spawnFromProcess）
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
        // iOS: llama.xcframework 已通过 pbxproj 链接+嵌入，App 启动期由 dyld 加载进进程，
        // 符号进入进程空间。按 llama_cpp_dart 官方设计用 spawnFromProcess
        // (内部 DynamicLibrary.process() / RTLD_DEFAULT 查找)，无需运行时 dlopen
        // 指定路径，也不依赖框架自身带 LC_RPATH —— App 的 LD_RUNPATH_SEARCH_PATHS
        // 含 @executable_path/Frameworks，启动期即可解析 @rpath/llama.framework/llama。
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
