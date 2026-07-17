import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;
import 'package:socratic_ai/core/constants.dart';
import 'package:socratic_ai/core/engine/dialogue_engine.dart';
import 'package:socratic_ai/core/engine/llama_service.dart';
import 'package:socratic_ai/core/logger.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/models/dashboard_models.dart';
import 'package:socratic_ai/core/think_tag_stripper.dart';

class StrategistPrompter implements DialogueEngine {
  final LlamaEngine _engine;
  EngineChat? _chat;

  final List<String> _recentQuestions = [];
  int _estimatedTokens = 0;

  static int get _contextWarnThreshold =>
      (AppConstants.modelContextSize * 0.85).round();

  StrategistPrompter(this._engine);

  @override
  bool get isReady => true;

  @override
  Future<bool> initialize({List<Goal> existingGoals = const []}) async {
    try {
      final prompt = _buildSystemPrompt(existingGoals: existingGoals);
      _chat = await _engine.createChat();
      _chat!.addSystem(prompt);
      _estimatedTokens = LlamaService.estimateTokens(prompt);
      return true;
    } catch (e) {
      AppLogger.error('StrategistPrompter', '初始化失败', e);
      return false;
    }
  }

  @override
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
    if (_chat == null) {
      AppLogger.warn('StrategistPrompter', '引擎未初始化');
      yield '军师尚在准备中，请稍后再来。';
      return;
    }

    if (_isDuplicate(userMessage)) {
      _chat!.addUser('$userMessage（请从不同的角度回答，不要重复之前的观点）');
    } else {
      _chat!.addUser(userMessage);
    }

    _estimatedTokens += LlamaService.estimateTokens(userMessage);

    if (_estimatedTokens > _contextWarnThreshold) {
      AppLogger.warn('StrategistPrompter',
          '上下文接近上限: ~$_estimatedTokens / ${AppConstants.modelContextSize} tokens');
    }

    final buffer = StringBuffer();
    try {
      await for (final event in _chat!.generate(
        sampler: const SamplerParams(
          temperature: 0.7,
          topP: 0.9,
          repeatPenalty: 1.1,
        ),
        maxTokens: 2048,
      )) {
        if (event is TokenEvent) {
          buffer.write(event.text);
          yield event.text;
        }
      }

      final fullReply = stripThinkTags(buffer.toString());
      if (fullReply.isNotEmpty) {
        _chat!.addAssistant(fullReply);
        _estimatedTokens += LlamaService.estimateTokens(fullReply);
      }
    } catch (e) {
      AppLogger.error('StrategistPrompter', '生成回复失败', e);
      yield '\n\n[军师暂时无法回应，请稍后再试]';
    }
  }

  @override
  void dispose() {
    _chat?.dispose();
    _chat = null;
  }

  // ================================================================
  // 去重
  // ================================================================

  bool _isDuplicate(String input) {
    final trimmed = input.trim();
    if (_recentQuestions.isEmpty) {
      _recentQuestions.add(trimmed);
      return false;
    }

    if (_recentQuestions.last == trimmed) return true;

    final lcs = _lcsSimilarity(_recentQuestions.last, trimmed);
    if (lcs > 0.8) return true;

    _recentQuestions.add(trimmed);
    if (_recentQuestions.length > 5) _recentQuestions.removeAt(0);
    return false;
  }

  double _lcsSimilarity(String a, String b) {
    final m = a.length;
    final n = b.length;
    final dp = List.generate(m + 1, (_) => List.filled(n + 1, 0));
    for (var i = 1; i <= m; i++) {
      for (var j = 1; j <= n; j++) {
        if (a[i - 1] == b[j - 1]) {
          dp[i][j] = dp[i - 1][j - 1] + 1;
        } else {
          dp[i][j] =
              dp[i - 1][j] > dp[i][j - 1] ? dp[i - 1][j] : dp[i][j - 1];
        }
      }
    }
    final lcsLen = dp[m][n];
    return lcsLen / (m > n ? m : n);
  }

  // ================================================================
  // 军师系统提示词
  // ================================================================

  static String _buildSystemPrompt({List<Goal> existingGoals = const []}) {
    final goalContext = existingGoals.isEmpty
        ? ''
        : '\n## 主公已有目标\n${existingGoals.map((g) => "- [${g.status.name}] ${g.title}").join('\n')}\n\n如果主公聊到与已有目标相关的话题，可以主动关联。如果新想法与已有目标相似，建议合并而非新建。\n';

    return '''你是军师。主公来找你商量事情，你的职责是：

1. 先理解主公的真实处境和核心诉求
2. 帮主公把模糊的问题拆解成清晰的子问题
3. 给出具体的分析和可执行的策略建议
4. 区分"主公自己能做的"和"需要外部条件配合的"
5. 在适当时候追问，帮助主公想得更深
$goalContext
风格要求：
- 像朋友一样真诚，不端着
- 给具体建议，不说空话
- 分析为什么这样建议，让主公理解背后的逻辑
- 每次回复控制在 3-5 句话内，简洁有力
- 不要使用 <think> 或 <思考> 标签
- 目标需要主公确认后才能生效，不要假设目标已定''';
  }
}
