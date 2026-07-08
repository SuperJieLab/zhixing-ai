import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;

import 'package:socratic_ai/core/models/chat_models.dart';

/// 洞察总结服务
///
/// 接收完整对话历史，调用 LLM 提取结构化洞察。
/// 通过 [LlamaEngine] 创建独立的 [EngineChat]，
/// 不干扰正在进行的对话 session。
class InsightService {
  final LlamaEngine _engine;

  InsightService(this._engine);

  // ================================================================
  // 系统提示词
  // ================================================================

  static const _systemPrompt =
      '你是一位思维教练。请分析以下对话，提取用户的核心洞察。\n'
      '\n'
      '要求：\n'
      '1. 从对话中发现用户隐藏的价值观、假设、认知矛盾\n'
      '2. 每条核心洞察用简洁的陈述句表达（不超过 20 字）\n'
      '3. 价值观标签用 2-4 字的关键词\n'
      '4. 严格只输出 JSON，不要输出任何解释性文字\n'
      '\n'
      '输出格式：\n'
      '{"core_insights":["洞察1","洞察2","洞察3"],'
      '"underlying_values":["价值观1","价值观2"],'
      '"contradictions_found":["矛盾1"],'
      '"next_topic_suggestion":"建议的下一个话题"}';

  // ================================================================
  // 公开接口
  // ================================================================

  /// 分析对话并返回结构化洞察
  ///
  /// [topic] 对话话题，[conversation] 完整消息列表。
  /// 模型未加载时返回空结果（前端展示提示信息）。
  Future<InsightResult> analyze(
    String topic,
    List<ChatMessage> conversation,
  ) async {
    // 构建完整对话文本
    final conversationText = _buildConversationText(topic, conversation);
    debugPrint('[InsightService] 对话长度: ${conversationText.length} 字');

    try {
      // 创建独立的 chat 实例
      final chat = await _engine.createChat();
      try {
        chat.addSystem(_systemPrompt);
        chat.addUser(conversationText);

        // 流式收集完整回复
        final buffer = StringBuffer();
        await for (final event in chat.generate(
          sampler: const SamplerParams(
            temperature: 0.3, // 洞察提取需要稳定，低温度
            topP: 0.8,
            repeatPenalty: 1.1,
          ),
          maxTokens: 256,
        )) {
          if (event is TokenEvent) {
            buffer.write(event.text);
          }
        }

        final rawResponse = buffer.toString().trim();
        debugPrint('[InsightService] 原始回复: $rawResponse');
        return _parseResponse(rawResponse);
      } finally {
        chat.dispose();
      }
    } catch (e, stack) {
      debugPrint('[InsightService] 洞察生成失败: $e');
      debugPrintStack(stackTrace: stack);
      return const InsightResult(
        coreInsights: [],
        underlyingValues: [],
        contradictionsFound: [],
        nextTopicSuggestion: null,
      );
    }
  }

  // ================================================================
  // 私有
  // ================================================================

  /// 将对话历史格式化为纯文本
  String _buildConversationText(
    String topic,
    List<ChatMessage> conversation,
  ) {
    final buffer = StringBuffer();
    buffer.writeln('话题：$topic\n');
    for (final msg in conversation) {
      final role = msg.role == MessageRole.ai ? 'AI' : '用户';
      buffer.writeln('$role：${msg.content}');
    }
    return buffer.toString();
  }

  /// 解析 LLM 输出的 JSON（三层回退）
  InsightResult _parseResponse(String raw) {
    // 层 1：直接 JSON 解析
    try {
      return _jsonToResult(jsonDecode(raw.trim()) as Map<String, dynamic>);
    } catch (_) {
      // 继续尝试
    }

    // 层 2：提取 markdown 代码块
    final codeBlock = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```');
    final codeMatch = codeBlock.firstMatch(raw);
    if (codeMatch != null) {
      try {
        return _jsonToResult(
          jsonDecode(codeMatch.group(1)!.trim()) as Map<String, dynamic>,
        );
      } catch (_) {
        // 继续尝试
      }
    }

    // 层 3：提取最外层 JSON 对象
    final jsonObj = RegExp(r'\{[\s\S]*\}');
    final jsonMatch = jsonObj.firstMatch(raw);
    if (jsonMatch != null) {
      try {
        return _jsonToResult(
          jsonDecode(jsonMatch.group(0)!) as Map<String, dynamic>,
        );
      } catch (_) {
        // 继续尝试
      }
    }

    // 兜底：将原始文本作为单条洞察展示
    debugPrint('[InsightService] JSON 解析全部失败，使用原始文本兜底');
    return InsightResult(
      coreInsights: [raw],
      underlyingValues: const [],
      contradictionsFound: const [],
      nextTopicSuggestion: null,
    );
  }

  /// JSON Map → InsightResult 转换（容错处理缺失字段）
  InsightResult _jsonToResult(Map<String, dynamic> json) {
    List<String> extractList(dynamic value) {
      if (value is List) {
        return value.map((e) => e.toString()).toList();
      }
      return [];
    }

    return InsightResult(
      coreInsights: extractList(json['core_insights']),
      underlyingValues: extractList(json['underlying_values']),
      contradictionsFound: extractList(json['contradictions_found']),
      nextTopicSuggestion: json['next_topic_suggestion'] as String?,
    );
  }
}
