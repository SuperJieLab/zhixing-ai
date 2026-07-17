import 'dart:convert';
import 'dart:math' as math;

import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;

import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/engine/llama_service.dart';
import 'package:zhixing_ai/core/logger.dart';
import 'package:zhixing_ai/core/models/chat_models.dart';
import 'package:zhixing_ai/core/models/conversation.dart';
import 'package:zhixing_ai/core/models/dashboard_models.dart';
import 'package:zhixing_ai/features/strategy_brief/engine/chat_utils.dart';
import 'package:zhixing_ai/features/strategy_brief/models/extraction_result.dart';
import 'package:zhixing_ai/core/think_tag_stripper.dart';

/// 对话提取引擎
///
/// 一次性分析——取整个对话历史，调 LLM 提取结构化结果：
///   - new_goals：新目标（status=proposed，需用户确认）
///   - goal_updates：已有目标状态变更建议（不自动执行）
///   - strategies：每个目标的执行步骤（关联 goal_title）
///   - cross_patterns：跨对话自我认知模式
///
/// 上下文保护：自动截断对话，保留最近的不超 token 预算的消息。
/// 输出保护：maxTokens=2048，足够丰富的 JSON 提取结果。
/// 依赖：LlamaEngine + chat_utils + think_tag_stripper
/// 消费方：StrategyBriefProvider（唯一）

class StrategistExtractor {
  final LlamaEngine _engine;

  StrategistExtractor(this._engine);

  static const _systemPrompt = '''
你是一位军师。请首先判断以下对话是否包含值得关注的目标或策略。

如果对话内容为纯闲聊、情绪发泄（无进一步展开）、短试探，
或没有任何可执行的信息，请直接输出：
{"relevant": false}

如果对话包含实质内容，请提取目标、策略和关键信息，输出：
{
  "relevant": true,
  "new_goals": [...],
  "goal_updates": [...],
  "strategies": [...],
  "cross_patterns": [...]
}

提取要求：
1. 识别主公表达的目标（显性或隐性）
2. 同名目标自动合并（视为同一目标的补充），标注更新而非新建
3. 为每个目标建议 1-3 条可执行策略
4. 标注每条策略类型：selfAction / aiAssist / externalDep
5. 发现跨对话的模式或矛盾
6. 严格只输出 JSON，不要带 markdown 代码块标记
7. 新目标初始为「待确认」状态，需主公确认后才生效；已有目标状态变更仅为「建议」，不会自动执行

new_goals 格式（新建目标，初始为待确认）：
{"title":"...","category":"career|finance|relationship|health|growth|other","priority":1-5,"deadline":null或"2026-09-01","notes":"..."}

goal_updates 格式（仅建议，需主公确认后执行）：
{"goal_title":"已有目标标题(精确匹配)","suggested_status":"completed|paused","reason":"为什么建议变更"}
# 注意：只能建议 status 变更（completed 或 paused），不能建议改 title/category/priority

strategies 格式：
{"goal_title":"关联的目标标题","description":"...","type":"selfAction|aiAssist|externalDep","next_step":"下一步具体动作"}

cross_patterns 格式：
{"label":"模式名称","description":"详细描述"}
''';

  Future<ExtractionResult?> extract({
    required Conversation conversation,
    required List<Goal> existingGoals,
  }) async {
    final userMsgs =
        conversation.messages.where((m) => m.role == MessageRole.user).length;
    if (userMsgs < 2) {
      AppLogger.info(
          'StrategistExtractor', '对话过短($userMsgs 条用户消息)，跳过提取');
      return null;
    }

    final existingGoalsText = existingGoals.isNotEmpty
        ? '\n## 主公已有的目标\n${existingGoals.map((g) => "- [${g.status.name}] ${g.title}").join('\n')}\n'
        : '';

    final overheadTokens = LlamaService.estimateTokens(_systemPrompt) +
        LlamaService.estimateTokens(existingGoalsText);
    final budget = (AppConstants.modelContextSize * 0.85).round() - overheadTokens - 200;
    final messages = _truncateMessages(conversation.messages, budget);

    final conversationText =
        buildConversationText(conversation.topic, messages);
    AppLogger.info('StrategistExtractor',
        '提取上下文: overhead=$overheadTokens, budget=$budget, 使用 ${messages.length}/${conversation.messages.length} 条消息');

    final chat = await _engine.createChat();
    try {
      chat.addSystem(_systemPrompt);
      chat.addUser('$existingGoalsText\n## 本轮对话\n$conversationText');

      final buffer = StringBuffer();
      await for (final event in chat.generate(
        sampler: const SamplerParams(
          temperature: 0.3,
          topP: 0.8,
          repeatPenalty: 1.1,
        ),
        maxTokens: 2048,
      )) {
        if (event is TokenEvent) {
          buffer.write(event.text);
        }
      }

      final raw = buffer.toString().trim();
      final json = stripThinkTags(raw);
      AppLogger.info('StrategistExtractor',
          '原始回复: ${json.isEmpty ? '(空)' : json.substring(0, math.min(json.length, 200))}');

      if (json.isEmpty) {
        AppLogger.info('StrategistExtractor', 'LLM 返回空内容（可能仅含 think 标签）');
        return null;
      }

      final parsed = jsonDecode(json) as Map<String, dynamic>;
      if (parsed['relevant'] != true) {
        AppLogger.info('StrategistExtractor', 'LLM 判定无实质内容');
        return null;
      }

      final result = ExtractionResult.fromJson(parsed);
      AppLogger.info('StrategistExtractor',
          '提取完成: ${result.newGoals.length} 目标, ${result.strategies.length} 策略, ${result.crossPatterns.length} 模式');
      return result;
    } catch (e) {
      AppLogger.error('StrategistExtractor', '提取失败', e);
      return null;
    } finally {
      chat.dispose();
    }
  }

  /// Keep the most recent messages that fit within token budget.
  List<ChatMessage> _truncateMessages(
      List<ChatMessage> messages, int tokenBudget) {
    if (messages.isEmpty) return [];

    var used = 0;
    final kept = <ChatMessage>[];

    for (var i = messages.length - 1; i >= 0; i--) {
      final msg = messages[i];
      final tokens = LlamaService.estimateTokens(msg.content);
      if (used + tokens > tokenBudget) break;
      used += tokens;
      kept.insert(0, msg);
    }

    AppLogger.info('StrategistExtractor',
        '消息截断: ${messages.length}->${kept.length} 条, ~$used tokens');
    return kept;
  }
}
