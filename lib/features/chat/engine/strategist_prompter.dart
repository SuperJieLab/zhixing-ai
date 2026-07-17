import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;
import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/engine/llama_service.dart';
import 'package:zhixing_ai/core/logger.dart';
import 'package:zhixing_ai/core/models/chat_models.dart';
import 'package:zhixing_ai/core/models/dashboard_models.dart';
import 'package:zhixing_ai/core/think_tag_stripper.dart';

/// 军师对话引擎
///
/// 组合 [LlamaEngine] 提供完整对话能力：
///   - 模式 C（追问→建议→合并检测）：先理解需求，再给解法，检测与已有目标重叠
///   - 流式输出：逐 token yield，think 标签自动剥离（显示层不可见）
///   - 上下文管理：超 75% 窗口自动截断，保留最近 6 轮
///   - 去重检测：相似问题提示 LLM 换角度回答
///
/// 依赖：LlamaEngine（模型推理能力）+ AppConstants（上下文配置）
/// 消费方：ChatProvider（唯一），不跨 feature 共享。

class StrategistPrompter {
  final LlamaEngine _engine;
  EngineChat? _chat;

  final List<String> _recentQuestions = [];
  int _estimatedTokens = 0;
  List<({String role, String content})> _history = [];
  String _systemPrompt = '';

  static int get _contextWarnThreshold =>
      (AppConstants.modelContextSize * 0.75).round();

  StrategistPrompter(this._engine);

  bool get isReady => true;

  Future<bool> initialize({List<Goal> existingGoals = const []}) async {
    try {
      _systemPrompt = _buildSystemPrompt(existingGoals: existingGoals);
      _chat = await _engine.createChat();
      _chat!.addSystem(_systemPrompt);
      _estimatedTokens = LlamaService.estimateTokens(_systemPrompt);
      return true;
    } catch (e) {
      AppLogger.error('StrategistPrompter', '初始化失败', e);
      return false;
    }
  }

  void seedHistory(List<ChatMessage> messages) {
    _history.clear();
    for (final msg in messages) {
      _history.add((role: msg.role.name, content: msg.content));
      if (msg.content.isEmpty) continue;
      if (msg.role == MessageRole.user) {
        _chat!.addUser(msg.content);
      } else if (msg.role == MessageRole.ai) {
        _chat!.addAssistant(msg.content);
      }
      _estimatedTokens += LlamaService.estimateTokens(msg.content);
    }
  }

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

    _history.add((role: 'user', content: userMessage));
    _estimatedTokens += LlamaService.estimateTokens(userMessage);

    if (_estimatedTokens > _contextWarnThreshold) {
      AppLogger.warn('StrategistPrompter',
          '上下文接近上限 (~$_estimatedTokens tokens)，执行截断');
      await _truncateContext();
    }

    final buffer = StringBuffer();
    var passedThink = false;
    var suppressWhitespace = false;
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

          if (!passedThink) {
            final text = buffer.toString();
            final closeIdx1 = text.indexOf('</think>');
            final closeIdx2 = text.indexOf('</思考>');
            final closeIdx = closeIdx1 >= 0
                ? closeIdx1 + '</think>'.length
                : closeIdx2 >= 0
                    ? closeIdx2 + '</思考>'.length
                    : -1;

            if (closeIdx > 0) {
              passedThink = true;
              suppressWhitespace = true;
              final after = text.substring(closeIdx).trimLeft();
              if (after.isNotEmpty) {
                suppressWhitespace = false;
                yield after;
              }
              buffer.clear();
              buffer.write(after);
            }
            // else: still in think section, suppress output
          } else if (suppressWhitespace) {
            // Still absorbing whitespace after </think>
            final text = buffer.toString();
            final trimmed = text.trimLeft();
            if (trimmed.isNotEmpty) {
              suppressWhitespace = false;
              buffer.clear();
              buffer.write(trimmed);
              yield trimmed;
            }
          } else {
            yield event.text;
          }
        }
      }

      final fullReply = stripThinkTags(buffer.toString());
      if (fullReply.isNotEmpty) {
        _chat!.addAssistant(fullReply);
        _estimatedTokens += LlamaService.estimateTokens(fullReply);
        _history.add((role: 'assistant', content: fullReply));
      }
    } catch (e) {
      AppLogger.error('StrategistPrompter', '生成回复失败', e);
      yield '\n\n[军师暂时无法回应，请稍后再试]';
    }
  }

  Future<void> _truncateContext() async {
    // Keep only the last 6 exchanges (12 messages: user-assistant pairs)
    const keepCount = 12;
    if (_history.length <= keepCount) return;

    _history = _history.sublist(_history.length - keepCount).toList();

    // Rebuild chat session
    _chat?.dispose();
    _chat = await _engine.createChat();
    _chat!.addSystem(_systemPrompt);
    _estimatedTokens = LlamaService.estimateTokens(_systemPrompt);

    for (final msg in _history) {
      if (msg.content.isEmpty) continue;
      if (msg.role == 'user') {
        _chat!.addUser(msg.content);
      } else {
        _chat!.addAssistant(msg.content);
      }
      _estimatedTokens += LlamaService.estimateTokens(msg.content);
    }

    AppLogger.info('StrategistPrompter',
        '上下文截断完成: 保留最近 ${_history.length} 条消息, ~$_estimatedTokens tokens');
  }

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
- 目标需要主公确认后才能生效，不要假设目标已定''';
  }
}
