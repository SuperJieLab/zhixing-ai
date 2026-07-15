import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;
import 'package:socratic_ai/core/constants.dart';
import 'package:socratic_ai/core/engine/dialogue_engine.dart';
import 'package:socratic_ai/core/engine/llama_service.dart';
import 'package:socratic_ai/core/logger.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/think_tag_stripper.dart';

// ================================================================
// 追问阶段 — 梯度策略
// ================================================================

/// 追问阶段（随对话深度自动升级）
enum _ProbeStage {
  /// 1 轮 — 探索：帮用户展开话题
  exploration,

  /// 2-3 轮 — 深入：追问具体细节或例子
  deepening,

  /// 4-6 轮 — 挑战：质疑底层假设
  challenge,

  /// 7+ 轮 — 总结：引导回顾对话收获
  summary,
}

/// 每个阶段的追问方向标记（注入到用户消息中，指导模型）
const _stageHints = <_ProbeStage, String>{
  _ProbeStage.exploration: '追问方向：【探索】基于用户刚才的回答深入追问，问一个具体问题',
  _ProbeStage.deepening: '追问方向：【深入】追问具体细节或例子，比如"具体是指什么"',
  _ProbeStage.challenge: '追问方向：【挑战】挑战底层假设，比如"换个角度呢"',
  _ProbeStage.summary: '追问方向：【总结】引导回顾对话，问"最大的收获是什么"',
};

/// 短回答阈值（中文字符数），超过此值才不触发深入追问
const _shortAnswerThreshold = 20;

// ================================================================
// 苏格拉底系统提示词（对齐 PRD 6 条规则）
// ================================================================

const _socraticSystemPrompt = '''
你是一位苏格拉底式对话教练。你不会给建议或答案，你只通过提问帮用户自己找到答案。

**重要：直接输出追问问题，不要输出思考过程、不要输出推理步骤。**

## 对话规则
1. 每次只输出一个问题，不要附带任何解释
2. 问题必须基于用户刚才的回答深入挖掘
3. 如果用户回答比较浅，追问具体化：「你说的XX具体是指什么？」
4. 如果用户提出了一个判断，追问假设：「是什么让你这样认为？」
5. 如果发现用户前后矛盾，温和指出：「你之前说XX，现在说YY，这之间的变化是因为什么？」
6. 当对话达到足够深度（用户展现出新的自我认知），输出 [SUMMARY] 标记并给出洞察总结

用户消息中带有"追问方向"标记，你只需要基于该方向追问一个问题。
问题控制在 150 字以内，用中文。
不要给建议，不要一次问多个问题。
不要重复之前问过的内容。
''';

/// 苏格拉底式追问引擎
///
/// 实现 [DialogueEngine] 接口，组合 [LlamaService] 提供完整对话能力：
/// - Prompt 模板构建（PRD 6 条规则）
/// - 梯度追问策略（探索 → 深入 → 挑战 → 引导总结）
/// - 短回答自动升级到深入追问
/// - 去重检测
/// - Qwen think 标签剥离
/// - 流式输出
///
/// ChatProvider 只依赖 [DialogueEngine] 接口，不感知底层实现。
class SocraticPrompter implements DialogueEngine {
  final LlamaEngine _engine;
  EngineChat? _chat;

  /// 已生成的 AI 追问次数（0 表示还没生成过任何追问）
  /// 用于判断当前对话深度阶段：阶段 = _currentStage(_roundIndex + 1, ...)
  int _roundIndex = 0;

  /// 最近 3 轮的追问文本（用于去重检测）
  final List<String> _recentQuestions = [];

  /// 累计 token 估算（用于上下文监控）
  /// llama.cpp 的 KV cache 在超过 nCtx 时自动截断，
  /// 此计数器仅用于日志警告。
  int _estimatedTokens = 0;

  /// 上下文接近上限的警告阈值（约 85% nCtx）
  static int get _contextWarnThreshold =>
      (AppConstants.modelContextSize * 0.85).round();

  SocraticPrompter(this._engine);

  // ================================================================
  // DialogueEngine 接口实现
  // ================================================================

  @override
  bool get isReady => true;

  @override
  Future<bool> initialize() async {
    try {
      _chat = await _engine.createChat();
      _chat!.addSystem(_socraticSystemPrompt);
      return true;
    } catch (e) {
      AppLogger.error('SocraticPrompter', '初始化失败', e);
      return false;
    }
  }

  @override
  void seedContext(String welcomeMessage) {
    _chat!.addAssistant(welcomeMessage);
    _estimatedTokens += LlamaService.estimateTokens(_socraticSystemPrompt);
    _estimatedTokens += LlamaService.estimateTokens(welcomeMessage);
  }

  /// 回放历史消息到引擎上下文（恢复对话时用）
  void seedHistory(List<ChatMessage> messages) {
    for (final msg in messages) {
      if (msg.content.isEmpty) continue;
      if (msg.role == MessageRole.user) {
        _chat!.addUser(msg.content);
      } else if (msg.role == MessageRole.ai) {
        _chat!.addAssistant(msg.content);
      }
      _estimatedTokens += LlamaService.estimateTokens(msg.content);
    }
  }

  @override
  Stream<String> generateResponse(String userMessage) async* {
    final round = _roundIndex + 1;
    final stage = _currentStage(round, userMessage);
    final hint = _stageHints[stage]!;

    final formattedMessage = '$hint\n$userMessage';
    _chat!.addUser(formattedMessage);
    _estimatedTokens += LlamaService.estimateTokens(formattedMessage);

    // 上下文接近上限时日志警告（llama.cpp KV cache 自动截断早期消息）
    if (_estimatedTokens > _contextWarnThreshold) {
      AppLogger.warn(
        'SocraticPrompter',
        '上下文接近上限: ~$_estimatedTokens / ${AppConstants.modelContextSize} tokens',
      );
    }

    String? finalReply;

    for (int attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        const retryHint = '请基于当前追问方向，换一个角度追问，不要重复之前的问题。';
        _chat!.addUser(retryHint);
        _estimatedTokens += LlamaService.estimateTokens(retryHint);
      }

      final buffer = StringBuffer();
      try {
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
      } catch (e, stack) {
        AppLogger.error('SocraticPrompter', 'generate 异常', e, stack);
        yield '[生成错误: $e]';
        return;
      }

      final fullReply = stripThinkTags(buffer.toString());

      if (fullReply.isEmpty && attempt < 2) {
        AppLogger.info(
          'SocraticPrompter',
          '模型仅输出 think 内容，重试 (attempt=$attempt)',
        );
        continue;
      }

      if (attempt < 2 && _isDuplicateQuestion(fullReply)) {
        AppLogger.info(
          'SocraticPrompter',
          '检测到重复问题，重试 (attempt=$attempt)',
        );
        continue;
      }

      finalReply = fullReply;
      break;
    }

    _roundIndex++;

    if (finalReply != null && finalReply.isNotEmpty) {
      _addToHistory(finalReply);
      _estimatedTokens += LlamaService.estimateTokens(finalReply);
      // 逐字 yield，模拟流式效果
      for (int i = 0; i < finalReply.length; i++) {
        yield finalReply[i];
        if (i < finalReply.length - 1) {
          await Future.delayed(const Duration(milliseconds: 8));
        }
      }
    }
  }

  @override
  void reset() {
    _chat?.clearHistory();
    _chat?.addSystem(_socraticSystemPrompt);
    _roundIndex = 0;
    _recentQuestions.clear();
    _estimatedTokens = LlamaService.estimateTokens(_socraticSystemPrompt);
  }

  @override
  void dispose() {
    _chat?.dispose();
    _chat = null;
    // 不 dispose _engine —— 由 LlamaService 缓存池管理
    _roundIndex = 0;
    _recentQuestions.clear();
    _estimatedTokens = 0;
  }

  // ================================================================
  // 梯度追问阶段判断
  // ================================================================

  /// 根据对话轮次和用户回答长度，决定当前追问阶段
  _ProbeStage _currentStage(int round, String userMessage) {
    // 短回答优先升级：无论当前阶段，回答太短就深入追问
    if (userMessage.length < _shortAnswerThreshold) {
      return _ProbeStage.deepening;
    }

    if (round <= 1) return _ProbeStage.exploration;
    if (round <= 3) return _ProbeStage.deepening;
    if (round <= 6) return _ProbeStage.challenge;
    return _ProbeStage.summary;
  }

  // ================================================================
  // 去重检测
  // ================================================================

  /// 计算两个问题的关键词相似度（最长公共子串比例）
  double _questionSimilarity(String a, String b) {
    final cleanA = a.replaceAll(RegExp(r'[？，。！\s]'), '');
    final cleanB = b.replaceAll(RegExp(r'[？，。！\s]'), '');
    if (cleanA.isEmpty || cleanB.isEmpty) return 0;

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

  bool _isDuplicateQuestion(String question) {
    for (final recent in _recentQuestions) {
      if (_questionSimilarity(question, recent) > 0.8) return true;
    }
    return false;
  }

  void _addToHistory(String question) {
    _recentQuestions.add(question);
    if (_recentQuestions.length > 3) _recentQuestions.removeAt(0);
  }
}
