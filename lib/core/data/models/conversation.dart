import 'dart:convert';

import 'chat_models.dart';

/// 一次对话会话的持久化模型
///
/// 对应 sqflite 中的 conversations 表。
/// 是所有目标/策略的基本数据源。
/// status / messages / extractionJson 可在运行时就地更新。
class Conversation {
  final int? id;
  String topic;
  String status;
  final bool isFavorite;
  List<ChatMessage> messages;
  String? extractionJson;
  final DateTime createdAt;
  final DateTime updatedAt;

  Conversation({
    this.id,
    required this.topic,
    this.status = 'active',
    this.isFavorite = false,
    this.messages = const [],
    this.extractionJson,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 消息轮数（不含欢迎消息，用户消息数）
  int get totalRounds {
    return messages.where((m) => m.role == MessageRole.user).length;
  }

  // ================================================================
  // 反序列化
  // ================================================================

  factory Conversation.fromMap(Map<String, dynamic> map) {
    return Conversation(
      id: map['id'] as int?,
      topic: map['topic'] as String,
      status: map['status'] as String? ?? 'active',
      isFavorite: (map['is_favorite'] as int?) == 1,
      messages: _parseMessages(map['messages_json'] as String?),
      extractionJson: map['extraction_json'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }

  Conversation copyWith({
    int? id,
    String? topic,
    String? status,
    bool? isFavorite,
    List<ChatMessage>? messages,
    String? extractionJson,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Conversation(
      id: id ?? this.id,
      topic: topic ?? this.topic,
      status: status ?? this.status,
      isFavorite: isFavorite ?? this.isFavorite,
      messages: messages ?? this.messages,
      extractionJson: extractionJson ?? this.extractionJson,
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
}
