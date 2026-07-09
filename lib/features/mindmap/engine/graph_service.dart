import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;

import 'package:socratic_ai/core/models/chat_models.dart';

/// 思维图谱生成服务
///
/// 接收完整对话历史，调用 LLM 提取结构化图谱数据（节点 + 连线）。
/// 复用 [InsightService] 的模式：独立 EngineChat → JSON 输出 → 三层回退解析。
class GraphService {
  final LlamaEngine _engine;

  GraphService(this._engine);

  /// 匹配 Qwen 模型的 `&lt;think&gt;...&lt;/think&gt;` 推理标签
  static final _thinkTagPattern =
      RegExp(r'<think>[\s\S]*?</think>', multiLine: true);

  // ================================================================
  // 系统提示词
  // ================================================================

  static const _systemPrompt =
      '你是一位知识图谱分析师。请分析以下对话，提取其中的关键概念和它们之间的关系。\n'
      '\n'
      '要求：\n'
      '1. 从对话中提取 4-8 个关键概念作为节点\n'
      '2. 节点 type 为以下之一：\n'
      '   - "topic"：对话话题\n'
      '   - "insight"：用户的核心认知/洞察\n'
      '   - "value"：用户的底层价值观\n'
      '   - "action"：用户提及的行动或决策\n'
      '   - "contradiction"：用户的认知矛盾\n'
      '3. weight 值 0-1（topic 和核心 insight 给 1.0，次要节点给 0.5）\n'
      '4. 节点之间如果有明确关联（因果、包含、对比、矛盾），用 edge 连接\n'
      '5. edge 的 label 用 2-4 字简要描述关系（如"导致"、"包含"、"矛盾"）\n'
      '6. 严格只输出 JSON，不要输出任何解释性文字，不要输出 <think> 标签\n'
      '7. 每条 edge 必须包含 source, target, label, strength 四个字段\n'
      '8. JSON 必须为紧凑格式（单行，不要换行，不要多余空格）\n'
      '\n'
      '输出格式：\n'
      '{"nodes":[{"id":"n1","label":"职业转型","type":"topic","weight":1.0},'
      '{"id":"n2","label":"害怕失败","type":"insight","weight":1.0}],'
      '"edges":[{"source":"n1","target":"n2","label":"核心矛盾","strength":0.9}]}';

  // ================================================================
  // 公开接口
  // ================================================================

  /// 生成对话思维图谱
  ///
  /// [topic] 对话话题，[conversation] 完整消息列表。
  /// 模型未加载时返回空图谱（前端展示空状态提示）。
  Future<ConversationGraph> generate(
    String topic,
    List<ChatMessage> conversation,
  ) async {
    final conversationText = _buildConversationText(topic, conversation);
    debugPrint('[GraphService] 对话长度: ${conversationText.length} 字');

    try {
      final chat = await _engine.createChat();
      try {
        chat.addSystem(_systemPrompt);
        chat.addUser(conversationText);

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

        final rawResponse = buffer.toString().trim();
        debugPrint('[GraphService] 原始回复: $rawResponse');
        return _parseResponse(rawResponse);
      } finally {
        chat.dispose();
      }
    } catch (e, stack) {
      debugPrint('[GraphService] 图谱生成失败: $e');
      debugPrintStack(stackTrace: stack);
      return const ConversationGraph();
    }
  }

  // ================================================================
  // 私有
  // ================================================================

  String _buildConversationText(String topic, List<ChatMessage> conversation) {
    final buffer = StringBuffer();
    buffer.writeln('话题：$topic\n');
    for (final msg in conversation) {
      final role = msg.role == MessageRole.ai ? 'AI' : '用户';
      buffer.writeln('$role：${msg.content}');
    }
    return buffer.toString();
  }

  /// 三层回退 JSON 解析
  ConversationGraph _parseResponse(String raw) {
    // 层 0：剥离 Qwen 模型的 <think> 推理内容
    String cleaned = raw.replaceAll(_thinkTagPattern, '').trim();
    if (cleaned.isEmpty) cleaned = raw.trim();

    // 层 1：直接 JSON 解析
    try {
      return ConversationGraph.fromJson(
        jsonDecode(cleaned) as Map<String, dynamic>,
      );
    } catch (_) {
      // 继续尝试
    }

    // 层 2：提取 markdown 代码块
    final codeBlock = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```');
    final codeMatch = codeBlock.firstMatch(cleaned);
    if (codeMatch != null) {
      try {
        return ConversationGraph.fromJson(
          jsonDecode(codeMatch.group(1)!.trim()) as Map<String, dynamic>,
        );
      } catch (_) {
        // 继续尝试
      }
    }

    // 层 3：提取最外层 JSON 对象
    final jsonObj = RegExp(r'\{[\s\S]*\}');
    final jsonMatch = jsonObj.firstMatch(cleaned);
    if (jsonMatch != null) {
      try {
        return ConversationGraph.fromJson(
          jsonDecode(jsonMatch.group(0)!) as Map<String, dynamic>,
        );
      } catch (_) {
        // 继续尝试
      }
    }

    // 兜底：空图谱，UI 展示空状态
    debugPrint('[GraphService] JSON 解析全部失败');
    return const ConversationGraph();
  }
}
