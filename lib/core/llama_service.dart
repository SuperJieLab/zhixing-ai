import 'package:flutter/foundation.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';

/// 追问维度轮换表（5 个维度，按顺序循环）
const _dimensions = ['原因', '假设', '影响', '对比', '行动'];

/// 苏格拉底式教练的系统提示词（few-shot 版）
///
/// 追问维度由 Dart 端硬编码轮换，去重也在 Dart 端完成。
/// 开场白通过 addAssistant 注入 chat 历史。
const _socraticSystemPrompt = '''
你是一位苏格拉底式教练。你的任务是只通过提问帮助用户深入思考，不给建议、不做评判。

用户消息中包含追问维度标记，你只需要基于标记的维度追问一个问题：

## 示例
用户："追问维度：【原因】\n我觉得换工作是因为现在太累了"
你："累的背后是什么——是工作内容本身，还是节奏问题，还是成长空间不够？"

用户："追问维度：【行动】\n我想开始学一门新技术"
你："具体从哪一步开始？每天能拿出多少时间来？"

## 追问维度
- 【原因】→ 追问背后的动机、原因
- 【假设】→ 追问前提条件，换个角度思考
- 【影响】→ 追问带来的后果、长期影响
- 【对比】→ 追问差异、矛盾
- 【行动】→ 追问具体计划、第一步

## 规则
1. 先简要回应用户的观点，再提一个开放性问题
2. 问题控制在 150 字以内，用中文
3. 不要给建议，不要一次问多个问题
4. 不要重复之前问过的内容''';

/// LlamaService — 端侧 LLM 推理服务单例
///
/// 负责管理 [LlamaEngine] 的生命周期，将底层 Isolate 推理暴露为
/// 简洁的 stream API，供 [ChatProvider] 直接消费。
///
/// ## 追问维度轮换（防重复机制）
/// 小模型（1.5B）无法自主执行"抽象指令"，必须在 Dart 端硬编码：
/// - 每轮根据 `_roundIndex % 5` 选择追问维度
/// - 维度直接注入用户消息（"追问维度：【XX】"）
/// - 生成完整文本后检测重复（关键词相似度 > 60%），重复则切换维度重试
///
/// 使用方式：
/// ```dart
/// final service = LlamaService();
/// await service.loadModel(...);
/// await for (final token in service.generateResponse('用户输入')) {
///   print(token);
/// }
/// ```
class LlamaService {
  LlamaService._();
  static final LlamaService _instance = LlamaService._();
  factory LlamaService() => _instance;

  LlamaEngine? _engine;
  EngineChat? _chat;

  bool _isLoaded = false;
  bool _isLoading = false;

  /// 轮次计数，用于追问维度轮换
  int _roundIndex = 0;

  /// 最近 3 轮的问题（用于检测重复）
  final List<String> _recentQuestions = [];

  /// 对话开场白（由 ChatProvider 注入），首次 generate 前作为 assistant 消息写入 chat 历史
  String? _welcomeMessage;

  /// 模型是否已加载并就绪
  bool get isLoaded => _isLoaded;

  /// 是否正在加载中
  bool get isLoading => _isLoading;

  /// 当前设备的硬件加速器名称（Metal / Hexagon / null = CPU）
  String? get acceleratorName => _engine?.primaryAcceleratorName;

  /// 当前追问维度（调试用途）
  String get currentDimension => _getCurrentDimension();

  /// 注入对话开场白上下文。
  ///
  /// 必须在首次调用 [generateResponse] 之前调用。
  /// 将开场白作为 assistant 消息写入 chat 历史，
  /// 大模型就能知道对话话题和已说过的开场白。
  void seedConversationContext(String welcomeMessage) {
    if (_welcomeMessage != null) return; // 只注入一次
    _welcomeMessage = welcomeMessage;
    _chat?.addAssistant(welcomeMessage);
  }

  // ================================================================
  // 追问维度管理
  // ================================================================

  String _getCurrentDimension() => _dimensions[_roundIndex % _dimensions.length];

  /// 去除 Qwen3.5 的 `<think>` 推理内容，只保留最终回复。
  ///
  /// Qwen3.5 即使默认关闭 thinking，chat template 有时仍会输出
  /// `<think>推理过程</think>\\n\\n实际回复`。此方法检测并剥离。
  String _stripThinkingTags(String text) {
    // 找最后一个 `</think>`，取其后的内容
    final thinkEnd = text.lastIndexOf('</think>');
    if (thinkEnd == -1) return text.trim();
    final after = text.substring(thinkEnd + 8).trim();
    return after.isEmpty ? text.trim() : after;
  }

  /// 计算两个问题的关键词相似度（简单去重检测）
  double _questionSimilarity(String a, String b) {
    // 提取中文关键词（去除标点和虚词）
    final cleanA = a.replaceAll(RegExp(r'[？，。！\s]'), '');
    final cleanB = b.replaceAll(RegExp(r'[？，。！\s]'), '');
    if (cleanA.isEmpty || cleanB.isEmpty) return 0;
    // 计算最长公共子串占比
    int maxLen = 0;
    for (int i = 0; i < cleanA.length; i++) {
      for (int j = 0; j < cleanB.length; j++) {
        int len = 0;
        while (i + len < cleanA.length &&
               j + len < cleanB.length &&
               cleanA[i + len] == cleanB[j + len]) {
          len++;
        }
        if (len > maxLen) maxLen = len;
      }
    }
    return maxLen / cleanA.length;
  }

  /// 检测新问题是否与最近问题重复（相似度 > 60%）
  bool _isDuplicateQuestion(String question) {
    for (final recent in _recentQuestions) {
      if (_questionSimilarity(question, recent) > 0.6) return true;
    }
    return false;
  }

  /// 添加问题到历史（保留最近 3 个）
  void _addToHistory(String question) {
    _recentQuestions.add(question);
    if (_recentQuestions.length > 3) _recentQuestions.removeAt(0);
  }

  // ================================================================
  // 模型加载
  // ================================================================

  /// 加载 GGUF 模型并初始化推理引擎。
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
      debugPrint('[LlamaService] 库路径: $libraryPath');

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
        for (final d in _engine!.devices) {
          debugPrint('[LlamaService]   设备: ${d.name} (${d.type.name})');
        }
      }

      _chat = await _engine!.createChat();
      _chat!.addSystem(_socraticSystemPrompt);

      _isLoaded = true;
      debugPrint('[LlamaService] 模型加载完成 ✅');
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
      debugPrint('[LlamaService] 从进程符号加载模型: $modelPath');

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
      _chat!.addSystem(_socraticSystemPrompt);

      _isLoaded = true;
      debugPrint('[LlamaService] 模型加载完成 ✅（进程内符号）');
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
  // 生成回复（预生成 + 去重 + 流式 yield）
  // ================================================================

  /// 生成 AI 回复的 token 流。
  ///
  /// 流程：
  /// 1. 根据轮次选择追问维度，注入用户消息
  /// 2. 预生成完整回复（内部流式）
  /// 3. 检测是否重复，如重复则切换维度重试（最多 3 次）
  /// 4. 通过后逐字 yield，模拟流式效果
  /// 5. 轮次 +1
  Stream<String> generateResponse(String userMessage) async* {
    if (_chat == null) {
      yield '[错误：模型未加载，请先调用 loadModel]';
      return;
    }

    String dimension = _getCurrentDimension();
    final formattedMessage = '追问维度：【$dimension】\n$userMessage';

    _chat!.addUser(formattedMessage);

    String? finalReply;

    for (int attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        // 重试：发送修正指令
        _chat!.addUser('请基于【$dimension】维度，换一个角度追问，不要重复之前的问题。');
      }

      final buffer = StringBuffer();
      try {
        await for (final event in _chat!.generate(
          sampler: const SamplerParams(
            temperature: 0.85,
            topP: 0.92,
          ),
          maxTokens: 256,
        )) {
          if (event is TokenEvent) {
            buffer.write(event.text);
          }
        }
      } on StateError catch (e) {
        debugPrint('[LlamaService] StateError: $e');
        yield '[生成错误: ${e.toString()}]';
        return;
      } catch (e, stack) {
        debugPrint('[LlamaService] generate 异常: $e');
        debugPrintStack(stackTrace: stack);
        yield '[生成错误: ${e.toString()}]';
        return;
      }

      final fullReply = _stripThinkingTags(buffer.toString().trim());

      // 检测重复（第 1 轮开始检测）
      if (attempt < 2 && _isDuplicateQuestion(fullReply)) {
        debugPrint('[LlamaService] 检测到重复问题，切换维度重试 (attempt=$attempt)');
        _roundIndex++;
        dimension = _getCurrentDimension();
        continue;
      }

      finalReply = fullReply;
      break;
    }

    _roundIndex++;

    if (finalReply != null) {
      _addToHistory(finalReply);
      // 逐字 yield，模拟流式效果（每字约 8ms，约 125 字/秒）
      for (int i = 0; i < finalReply.length; i++) {
        yield finalReply[i];
        if (i < finalReply.length - 1) {
          await Future.delayed(const Duration(milliseconds: 8));
        }
      }
    }
  }

  /// 重置对话上下文（清空消息历史 + 轮次 + 去重缓存）
  void resetContext() {
    _chat?.clearHistory();
    _chat?.addSystem(_socraticSystemPrompt);
    _roundIndex = 0;
    _recentQuestions.clear();
    _welcomeMessage = null;
  }

  /// 释放引擎及所有资源
  Future<void> dispose() async {
    debugPrint('[LlamaService] 正在释放引擎...');
    _chat = null;
    _engine?.dispose();
    _engine = null;
    _isLoaded = false;
    _roundIndex = 0;
    _recentQuestions.clear();
    _welcomeMessage = null;
    debugPrint('[LlamaService] 引擎已释放');
  }
}
