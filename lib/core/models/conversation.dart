import 'dart:convert';

import 'chat_models.dart';
import 'package:socratic_ai/core/logger.dart';

/// 一次对话会话的持久化模型
///
/// 对应 sqflite 中的 conversations 表。
/// status / messages / insight / graph 可通过 ConversationService
/// 的 mutation 方法就地更新（同时刷新 DB），其余字段 immutable。
class Conversation {
  final int? id;
  String topic;
  String status;
  final bool isFavorite;
  List<ChatMessage> messages;
  InsightResult? insight;
  ConversationGraph? graph;
  String? extractionJson;
  final DateTime createdAt;
  final DateTime updatedAt;

  Conversation({
    this.id,
    required this.topic,
    this.status = 'active',
    this.isFavorite = false,
    this.messages = const [],
    this.insight,
    this.graph,
    this.extractionJson,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 消息轮数（不含欢迎消息，用户消息数）
  int get totalRounds {
    return messages.where((m) => m.role == MessageRole.user).length;
  }

  /// 是否有洞察总结
  bool get hasInsight => insight != null;

  /// 是否有思维图谱
  bool get hasGraph => graph != null;

  // ================================================================
  // 序列化
  // ================================================================

  /// 从 sqflite row Map 创建
  factory Conversation.fromMap(Map<String, dynamic> map) {
    return Conversation(
      id: map['id'] as int?,
      topic: map['topic'] as String,
      status: map['status'] as String? ?? 'active',
      isFavorite: (map['is_favorite'] as int?) == 1,
      messages: _parseMessages(map['messages_json'] as String?),
      insight: _parseInsight(map['insight_json'] as String?),
      graph: _parseGraph(map['graph_json'] as String?),
      extractionJson: map['extraction_json'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }

  /// 转换为 sqflite row Map
  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'topic': topic,
      'status': status,
      'is_favorite': isFavorite ? 1 : 0,
      'messages_json': _messagesToJson(messages),
      'insight_json': _insightToJson(insight),
      'graph_json': _graphToJson(graph),
      'extraction_json': extractionJson,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  /// 创建一个副本并更新字段（不可变模式）
  Conversation copyWith({
    int? id,
    String? topic,
    String? status,
    bool? isFavorite,
    List<ChatMessage>? messages,
    InsightResult? insight,
    ConversationGraph? graph,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Conversation(
      id: id ?? this.id,
      topic: topic ?? this.topic,
      status: status ?? this.status,
      isFavorite: isFavorite ?? this.isFavorite,
      messages: messages ?? this.messages,
      insight: insight ?? this.insight,
      graph: graph ?? this.graph,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  // ================================================================
  // 私有
  // ================================================================

  static List<ChatMessage> _parseMessages(String? json) {
    if (json == null || json.isEmpty) return [];
    final list = jsonDecode(json) as List;
    return list
        .map((e) => ChatMessage(
              role: MessageRole.values.firstWhere(
                (r) => r.name == (e['role'] as String),
              ),
              content: e['content'] as String,
              round: e['round'] as int,
            ))
        .toList();
  }

  static InsightResult? _parseInsight(String? json) {
    if (json == null || json.isEmpty) return null;
    final map = jsonDecode(json) as Map<String, dynamic>;
    return InsightResult(
      coreInsights: List<String>.from(map['core_insights'] ?? []),
      underlyingValues: List<String>.from(map['underlying_values'] ?? []),
      contradictionsFound:
          List<String>.from(map['contradictions_found'] ?? []),
      nextTopicSuggestion: map['next_topic_suggestion'] as String?,
    );
  }

  static String _messagesToJson(List<ChatMessage> messages) {
    return jsonEncode(
      messages
          .map((m) => {
                'role': m.role.name,
                'content': m.content,
                'round': m.round,
              })
          .toList(),
    );
  }

  static String? _insightToJson(InsightResult? insight) {
    if (insight == null) return null;
    return jsonEncode({
      'core_insights': insight.coreInsights,
      'underlying_values': insight.underlyingValues,
      'contradictions_found': insight.contradictionsFound,
      'next_topic_suggestion': insight.nextTopicSuggestion,
    });
  }

  static ConversationGraph? _parseGraph(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      final graph = ConversationGraph.fromJson(map);
      AppLogger.info('Conversation', '从 DB 加载图谱: ${graph.nodes.length} 节点, ${graph.edges.length} 边');
      return graph;
    } catch (e) {
      AppLogger.warn('Conversation', '图谱解析失败: $e');
      return null;
    }
  }

  static String? _graphToJson(ConversationGraph? graph) {
    if (graph == null) return null;
    return jsonEncode(graph.toJson());
  }
}
