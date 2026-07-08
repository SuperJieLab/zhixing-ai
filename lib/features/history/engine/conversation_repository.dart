import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/models/conversation.dart';

/// 会话持久化仓库（sqflite 单例）
///
/// 负责 conversations 表的所有 CRUD 操作。
/// 消息和洞察以 JSON 列存储。
class ConversationRepository {
  static Database? _db;

  /// 初始化数据库（应在 main() 中调用一次）
  static Future<void> initialize() async {
    final dbPath = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dbPath, 'socratic.db'),
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE conversations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            topic TEXT NOT NULL,
            status TEXT DEFAULT 'active',
            is_favorite INTEGER DEFAULT 0,
            messages_json TEXT,
            insight_json TEXT,
            graph_json TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE conversations ADD COLUMN graph_json TEXT',
          );
        }
      },
    );
  }

  Database get _ensureDb {
    if (_db == null) throw StateError('ConversationRepository 未初始化');
    return _db!;
  }

  /// 创建新会话，返回自增 id
  Future<int> create({required String topic}) async {
    final now = DateTime.now().toIso8601String();
    return _ensureDb.insert('conversations', {
      'topic': topic,
      'status': 'active',
      'created_at': now,
      'updated_at': now,
    });
  }

  /// 更新消息列表（整批覆盖 JSON）
  Future<void> updateMessages(int id, List<ChatMessage> messages) async {
    final list = messages
        .map((m) => {
              'role': m.role.name,
              'content': m.content,
              'round': m.round,
            })
        .toList();
    await _ensureDb.update(
      'conversations',
      {
        'messages_json': jsonEncode(list),
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 完成会话（写入洞察 + 标记 completed）
  Future<void> complete(int id, InsightResult? insight) async {
    final update = <String, dynamic>{
      'status': 'completed',
      'updated_at': DateTime.now().toIso8601String(),
    };
    if (insight != null) {
      update['insight_json'] = jsonEncode({
        'core_insights': insight.coreInsights,
        'underlying_values': insight.underlyingValues,
        'contradictions_found': insight.contradictionsFound,
        'next_topic_suggestion': insight.nextTopicSuggestion,
      });
    }
    await _ensureDb.update('conversations', update,
        where: 'id = ?', whereArgs: [id]);
  }

  /// 保存思维图谱 JSON
  Future<void> saveGraph(int id, ConversationGraph graph) async {
    await _ensureDb.update(
      'conversations',
      {
        'graph_json': jsonEncode(graph.toJson()),
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 切换收藏状态
  Future<void> toggleFavorite(int id, bool currentValue) async {
    await _ensureDb.update(
      'conversations',
      {'is_favorite': currentValue ? 0 : 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 获取所有会话（按 updated_at 倒序）
  Future<List<Conversation>> listAll() async {
    final rows = await _ensureDb.query(
      'conversations',
      orderBy: 'updated_at DESC',
    );
    return rows.map((r) => Conversation.fromMap(r)).toList();
  }

  /// 按 id 获取单条会话
  Future<Conversation?> getById(int id) async {
    final rows = await _ensureDb.query(
      'conversations',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    return Conversation.fromMap(rows.first);
  }

  /// 删除会话
  Future<void> delete(int id) async {
    await _ensureDb.delete('conversations', where: 'id = ?', whereArgs: [id]);
  }
}
