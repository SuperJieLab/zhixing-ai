import 'dart:convert';
import 'dart:math' as math;

import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;

import 'package:socratic_ai/core/chat_utils.dart';
import 'package:socratic_ai/core/logger.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/models/conversation.dart';
import 'package:socratic_ai/core/models/dashboard_models.dart';
import 'package:socratic_ai/core/think_tag_stripper.dart';

class ExtractionResult {
  final List<Goal> newGoals;
  final List<GoalUpdate> goalUpdates;
  final List<Strategy> strategies;
  final List<CrossPattern> crossPatterns;

  ExtractionResult({
    this.newGoals = const [],
    this.goalUpdates = const [],
    this.strategies = const [],
    this.crossPatterns = const [],
  });

  bool get hasContent =>
      newGoals.isNotEmpty ||
      goalUpdates.isNotEmpty ||
      strategies.isNotEmpty ||
      crossPatterns.isNotEmpty;

  factory ExtractionResult.fromJson(Map<String, dynamic> json) {
    final now = DateTime.now();
    return ExtractionResult(
      newGoals: (json['new_goals'] as List<dynamic>?)
              ?.map((g) => _parseGoal(g as Map<String, dynamic>, now))
              .toList() ??
          [],
      goalUpdates: (json['goal_updates'] as List<dynamic>?)
              ?.map((u) => GoalUpdate.fromJson(u as Map<String, dynamic>))
              .toList() ??
          [],
      strategies: (json['strategies'] as List<dynamic>?)
              ?.map((s) => Strategy(
                    goalId: 0,
                    description: s['description'] as String? ?? '',
                    type: _parseStrategyType(s['type'] as String?),
                    nextStep: s['next_step'] as String?,
                    createdAt: now,
                  ))
              .toList() ??
          [],
      crossPatterns: (json['cross_patterns'] as List<dynamic>?)
              ?.map((p) => CrossPattern(
                    label: p['label'] as String? ?? '',
                    description: p['description'] as String? ?? '',
                    detectedAt: now,
                  ))
              .toList() ??
          [],
    );
  }

  static Goal _parseGoal(Map<String, dynamic> g, DateTime now) {
    return Goal(
      title: g['title'] as String? ?? '',
      category: GoalCategory.values.firstWhere(
        (e) => e.name == (g['category'] as String?),
        orElse: () => GoalCategory.other,
      ),
      priority: g['priority'] as int? ?? 3,
      deadline: g['deadline'] as String?,
      notes: g['notes'] as String?,
      createdAt: now,
      updatedAt: now,
    );
  }

  static StrategyType _parseStrategyType(String? type) {
    return StrategyType.values.firstWhere(
      (e) => e.name == type,
      orElse: () => StrategyType.selfAction,
    );
  }
}

class GoalUpdate {
  final String goalTitle;
  final GoalStatus? newStatus;
  final String? newNotes;
  final String reason;

  GoalUpdate({
    required this.goalTitle,
    this.newStatus,
    this.newNotes,
    this.reason = '',
  });

  factory GoalUpdate.fromJson(Map<String, dynamic> json) {
    return GoalUpdate(
      goalTitle: json['goal_title'] as String? ?? '',
      newStatus: json['new_status'] != null
          ? GoalStatus.values.firstWhere(
              (e) => e.name == json['new_status'],
              orElse: () => GoalStatus.active,
            )
          : null,
      newNotes: json['new_notes'] as String?,
      reason: json['reason'] as String? ?? '',
    );
  }
}

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

new_goals 格式：
{"title":"...","category":"career|finance|relationship|health|growth|other","priority":1-5,"deadline":null或"2026-09-01","notes":"..."}

goal_updates 格式：
{"goal_title":"已有目标标题(精确匹配)","new_status":"active|completed|paused","new_notes":"...","reason":"为什么更新"}

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

    final conversationText =
        buildConversationText(conversation.topic, conversation.messages);

    final existingGoalsText = existingGoals.isNotEmpty
        ? '\n## 主公已有的目标\n${existingGoals.map((g) => "- [${g.status.name}] ${g.title}").join('\n')}\n'
        : '';

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
        maxTokens: 4096,
      )) {
        if (event is TokenEvent) {
          buffer.write(event.text);
        }
      }

      final raw = buffer.toString().trim();
      final json = stripThinkTags(raw);
      AppLogger.info('StrategistExtractor',
          '原始回复: ${json.substring(0, math.min(json.length, 200))}');

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
}
