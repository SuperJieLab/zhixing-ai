# Day 5a — 端侧会话持久化 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 用户聊过的每一轮对话持久化到本地 sqflite，支持历史列表查看、回看洞察、收藏、删除。

**Architecture:** ConversationRepository（sqflite CRUD 单例）→ ConversationProvider（ChangeNotifier 状态管理）→ HistoryPage + ConversationCard（UI）。ChatPage 在创建、每轮完成、结束对话时写入数据库。

**Tech Stack:** sqflite + path (provider) / Flutter / Provider / dart:convert

**设计文档：** 已合并至 `docs/demo-plan-socratic-ai.md` 第五节「历史列表页」。

---

### Task 1: 添加 sqflite 依赖 + Conversation 数据模型

**Files:**
- Modify: `pubspec.yaml`
- Create: `lib/core/models/conversation.dart`

**Step 1: 添加 sqflite 和 path 依赖**

在 `pubspec.yaml` 的 `dependencies` 下添加：

```yaml
  sqflite: ^2.4.1
  path: ^1.9.0
```

Run: `flutter pub get`
Expected: 成功安装

**Step 2: 创建 Conversation 数据模型**

```dart
// lib/core/models/conversation.dart
import 'dart:convert';

import 'chat_models.dart';

/// 一次对话会话的持久化模型
class Conversation {
  final int? id;           // null 表示未入库
  final String topic;      // 话题标题
  final String status;     // 'active' / 'completed'
  final bool isFavorite;
  final List<ChatMessage> messages;
  final InsightResult? insight;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Conversation({
    this.id,
    required this.topic,
    this.status = 'active',
    this.isFavorite = false,
    this.messages = const [],
    this.insight,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 消息数量（不含欢迎消息）
  int get totalRounds => (messages.length / 2).ceil();

  /// 是否有洞察总结
  bool get hasInsight => insight != null;

  /// 从 sqflite row Map 创建
  factory Conversation.fromMap(Map<String, dynamic> map) {
    List<ChatMessage> parseMessages(String? json) {
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

    InsightResult? parseInsight(String? json) {
      if (json == null || json.isEmpty) return null;
      final map = jsonDecode(json) as Map<String, dynamic>;
      return InsightResult(
        coreInsights: List<String>.from(map['core_insights'] ?? []),
        underlyingValues: List<String>.from(map['underlying_values'] ?? []),
        contradictionsFound: List<String>.from(map['contradictions_found'] ?? []),
        nextTopicSuggestion: map['next_topic_suggestion'] as String?,
      );
    }

    return Conversation(
      id: map['id'] as int?,
      topic: map['topic'] as String,
      status: map['status'] as String? ?? 'active',
      isFavorite: (map['is_favorite'] as int?) == 1,
      messages: parseMessages(map['messages_json'] as String?),
      insight: parseInsight(map['insight_json'] as String?),
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
      'messages_json': jsonEncode(
        messages
            .map((m) => {'role': m.role.name, 'content': m.content, 'round': m.round})
            .toList(),
      ),
      'insight_json': insight != null
          ? jsonEncode({
              'core_insights': insight!.coreInsights,
              'underlying_values': insight!.underlyingValues,
              'contradictions_found': insight!.contradictionsFound,
              'next_topic_suggestion': insight!.nextTopicSuggestion,
            })
          : null,
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
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
```

Run: `flutter analyze lib/core/models/conversation.dart`
Expected: No issues

---

### Task 2: 创建 ConversationRepository

**Files:**
- Create: `lib/features/history/engine/conversation_repository.dart`

**Step 1: 实现 sqflite CRUD 单例**

```dart
// lib/features/history/engine/conversation_repository.dart
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
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE conversations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            topic TEXT NOT NULL,
            status TEXT DEFAULT 'active',
            is_favorite INTEGER DEFAULT 0,
            messages_json TEXT,
            insight_json TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
      },
    );
  }

  Database get _ensureDb {
    if (_db == null) throw StateError('ConversationRepository 未初始化');
    return _db!;
  }

  /// 创建新会话，返回 id
  Future<int> create({required String topic}) async {
    final now = DateTime.now().toIso8601String();
    return _ensureDb.insert('conversations', {
      'topic': topic,
      'status': 'active',
      'created_at': now,
      'updated_at': now,
    });
  }

  /// 更新消息列表
  Future<void> updateMessages(int id, List<ChatMessage> messages) async {
    final json = _messagesToJson(messages);
    await _ensureDb.update(
      'conversations',
      {
        'messages_json': json,
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
      update['insight_json'] = _insightToJson(insight);
    }
    await _ensureDb.update('conversations', update,
        where: 'id = ?', whereArgs: [id]);
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

  // ================================================================
  // 私有
  // ================================================================

  String _messagesToJson(List<ChatMessage> messages) {
    return '[${messages.map((m) => '{"role":"${m.role.name}","content":${_escapeJson(m.content)},"round":${m.round}}').join(',')}]';
  }

  String _insightToJson(InsightResult insight) {
    final insights = insight.coreInsights.map(_escapeJson).join('","');
    final values = insight.underlyingValues.map(_escapeJson).join('","');
    final contradictions =
        insight.contradictionsFound.map(_escapeJson).join('","');
    final nextTopic = insight.nextTopicSuggestion != null
        ? '"${_escapeJson(insight.nextTopicSuggestion!)}"'
        : 'null';
    return '{"core_insights":["$insights"],"underlying_values":["$values"],"contradictions_found":["$contradictions"],"next_topic_suggestion":$nextTopic}';
  }

  String _escapeJson(String s) {
    return s
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n');
  }
}
```

等等——手动拼接 JSON 容易出错。改为用 `dart:convert` 的 `jsonEncode`：

**修正版实现**：

```dart
// lib/features/history/engine/conversation_repository.dart
import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/models/conversation.dart';

class ConversationRepository {
  static Database? _db;

  static Future<void> initialize() async {
    final dbPath = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dbPath, 'socratic.db'),
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE conversations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            topic TEXT NOT NULL,
            status TEXT DEFAULT 'active',
            is_favorite INTEGER DEFAULT 0,
            messages_json TEXT,
            insight_json TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
      },
    );
  }

  Database get _ensureDb {
    if (_db == null) throw StateError('ConversationRepository 未初始化');
    return _db!;
  }

  Future<int> create({required String topic}) async {
    final now = DateTime.now().toIso8601String();
    return _ensureDb.insert('conversations', {
      'topic': topic,
      'status': 'active',
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<void> updateMessages(int id, List<ChatMessage> messages) async {
    final list = messages
        .map((m) => {'role': m.role.name, 'content': m.content, 'round': m.round})
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

  Future<void> toggleFavorite(int id, bool currentValue) async {
    await _ensureDb.update(
      'conversations',
      {'is_favorite': currentValue ? 0 : 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<Conversation>> listAll() async {
    final rows = await _ensureDb.query(
      'conversations',
      orderBy: 'updated_at DESC',
    );
    return rows.map((r) => Conversation.fromMap(r)).toList();
  }

  Future<Conversation?> getById(int id) async {
    final rows = await _ensureDb.query(
      'conversations',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    return Conversation.fromMap(rows.first);
  }

  Future<void> delete(int id) async {
    await _ensureDb.delete('conversations', where: 'id = ?', whereArgs: [id]);
  }
}
```

**Step 2: 在 main.dart 中初始化**

Run: `flutter analyze lib/core/models/conversation.dart lib/features/history/engine/conversation_repository.dart`
Expected: No issues

---

### Task 3: 创建 ConversationProvider

**Files:**
- Create: `lib/features/history/providers/conversation_provider.dart`

**Step 1: 实现 ChangeNotifier**

```dart
// lib/features/history/providers/conversation_provider.dart
import 'package:flutter/foundation.dart';
import 'package:socratic_ai/core/models/conversation.dart';
import 'package:socratic_ai/features/history/engine/conversation_repository.dart';

/// 历史会话列表状态管理
///
/// 持有全部历史会话列表，提供加载、收藏切换、删除操作。
class ConversationProvider extends ChangeNotifier {
  final ConversationRepository _repo = ConversationRepository();

  List<Conversation> _conversations = [];
  bool _isLoading = false;

  List<Conversation> get conversations => _conversations;
  bool get isLoading => _isLoading;

  /// 从数据库加载所有会话
  Future<void> loadAll() async {
    _isLoading = true;
    notifyListeners();
    try {
      _conversations = await _repo.listAll();
    } catch (e) {
      debugPrint('[ConversationProvider] 加载失败: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 切换收藏状态
  Future<void> toggleFavorite(int id) async {
    final index = _conversations.indexWhere((c) => c.id == id);
    if (index == -1) return;

    final conv = _conversations[index];
    await _repo.toggleFavorite(id, conv.isFavorite);
    _conversations[index] = conv.copyWith(isFavorite: !conv.isFavorite);
    notifyListeners();
  }

  /// 删除会话
  Future<void> deleteConversation(int id) async {
    await _repo.delete(id);
    _conversations.removeWhere((c) => c.id == id);
    notifyListeners();
  }
}
```

Run: `flutter analyze lib/features/history/providers/conversation_provider.dart`
Expected: No issues

---

### Task 4: 创建 ConversationCard widget

**Files:**
- Create: `lib/features/history/widgets/conversation_card.dart`

**Step 1: 实现卡片组件**

```dart
// lib/features/history/widgets/conversation_card.dart
import 'package:flutter/material.dart';
import 'package:socratic_ai/core/models/conversation.dart';
import 'package:socratic_ai/core/theme.dart';

/// 历史对话卡片
///
/// 展示话题标题、轮次数、相对时间、洞察摘要。
/// 右侧收藏星标，支持左滑删除回调。
class ConversationCard extends StatelessWidget {
  final Conversation conversation;
  final VoidCallback onTap;
  final VoidCallback onFavoriteToggle;
  final VoidCallback onDelete;

  const ConversationCard({
    super.key,
    required this.conversation,
    required this.onTap,
    required this.onFavoriteToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final conv = conversation;
    final firstInsight = conv.hasInsight && conv.insight!.coreInsights.isNotEmpty
        ? conv.insight!.coreInsights.first
        : null;

    return Dismissible(
      key: Key('conversation_${conv.id}'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async {
        return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('删除对话'),
            content: Text('确定删除「${conv.topic}」的对话记录吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child:
                    const Text('删除', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        );
      },
      onDismissed: (_) => onDelete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: Colors.red.shade50,
        child: const Icon(Icons.delete_outline, color: Colors.red),
      ),
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            border:
                Border(bottom: BorderSide(color: Color(0xFFE8E4DF), width: 0.5)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      conv.topic,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${conv.totalRounds} 轮对话 · ${_formatTime(conv.updatedAt)}',
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    if (conv.hasInsight && firstInsight != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        firstInsight,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppTheme.primary,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              GestureDetector(
                onTap: onFavoriteToggle,
                child: Icon(
                  conv.isFavorite ? Icons.star : Icons.star_border,
                  color: conv.isFavorite
                      ? AppTheme.accent
                      : AppTheme.textSecondary,
                  size: 22,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    return '${dt.month}/${dt.day}';
  }
}
```

Run: `flutter analyze lib/features/history/widgets/conversation_card.dart`
Expected: No issues

---

### Task 5: 重写 HistoryPage

**Files:**
- Modify: `lib/features/history/history_page.dart`

**Step 1: 重写为有状态 + Provider**

```dart
// lib/features/history/history_page.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:socratic_ai/core/models/conversation.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/history/providers/conversation_provider.dart';
import 'package:socratic_ai/features/history/widgets/conversation_card.dart';
import 'package:socratic_ai/features/insights/insights_page.dart';

/// 历史对话列表页
///
/// 展示所有已完成/进行中的会话记录。
/// 支持查看洞察、收藏、删除。
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  @override
  void initState() {
    super.initState();
    // 首次加载时从数据库拉取
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ConversationProvider>().loadAll();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        surfaceTintColor: Colors.transparent,
        title: Consumer<ConversationProvider>(
          builder: (_, provider, __) {
            return Text(
              provider.conversations.isEmpty
                  ? '历史对话'
                  : '历史对话 (${provider.conversations.length})',
            );
          },
        ),
      ),
      body: Consumer<ConversationProvider>(
        builder: (_, provider, __) {
          if (provider.isLoading) {
            return const Center(
              child: CircularProgressIndicator(color: AppTheme.primary),
            );
          }

          if (provider.conversations.isEmpty) {
            return _buildEmptyState();
          }

          return ListView.separated(
            itemCount: provider.conversations.length,
            separatorBuilder: (_, __) => const SizedBox.shrink(),
            itemBuilder: (_, index) {
              final conv = provider.conversations[index];
              return ConversationCard(
                conversation: conv,
                onTap: () => _openInsight(conv),
                onFavoriteToggle: () => provider.toggleFavorite(conv.id!),
                onDelete: () => provider.deleteConversation(conv.id!),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.history, size: 48, color: AppTheme.textSecondary),
          const SizedBox(height: 16),
          Text(
            '还没有对话记录',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            '开始第一次探索吧',
            style: TextStyle(color: AppTheme.textSecondary),
          ),
        ],
      ),
    );
  }

  void _openInsight(Conversation conv) {
    if (conv.insight != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => InsightsPage(
            insight: conv.insight!,
            topic: conv.topic,
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该对话尚无洞察总结')),
      );
    }
  }
}
```

**Step 2: 更新 App 层注入 ConversationProvider**

在 `lib/app.dart` 中，往 `MultiProvider` 中添加：

```dart
ChangeNotifierProvider(create: (_) => ConversationProvider()),
```

注意：`_HistoryPageState.initState` 里用了 `context.read<ConversationProvider>()`，需要确保 Provider 在 widget 树上。当前 `app.dart` 里应该有 `MultiProvider`，往里加一个即可。

Run: `flutter analyze lib/features/history/ lib/app.dart`
Expected: No issues

---

### Task 6: ChatPage 集成持久化

**Files:**
- Modify: `lib/features/chat/chat_page.dart`

**Step 1: 添加 import**

```dart
import 'package:socratic_ai/features/history/engine/conversation_repository.dart';
```

**Step 2: 添加 _conversationId 字段**

在 `_ChatPageState` 类中添加：

```dart
  int? _conversationId;
```

**Step 3: 创建会话记录（在 Provider 创建后）**

在 `build()` 方法中，`ChangeNotifierProvider` 的 `create` 回调里：

```dart
return ChangeNotifierProvider(
  create: (_) {
    final provider = ChatProvider(topic: widget.topic, engine: _engine);
    // 引擎就绪时创建持久化记录
    if (_engine != null && _conversationId == null) {
      _conversationId = _createConversationRecord();
    }
    return provider;
  },
```

但 `create` 不能是 async，需要改成 fire-and-forget：

```dart
  Future<int?> _createConversationRecord() async {
    try {
      final repo = ConversationRepository();
      return await repo.create(topic: widget.topic);
    } catch (e) {
      debugPrint('[ChatPage] 创建会话记录失败: $e');
      return null;
    }
  }
```

更好的做法：在 `_ChatPageState` 中新增方法 `_persistMessages`，在 ChatProvider 每次完成 AI 回复后调用。但 ChatProvider 不知道 repository 的存在。有两个方案：

**方案 A**：通过回调注入
```dart
ChatProvider(
  topic: widget.topic,
  engine: _engine,
  onMessagesUpdated: (messages) => _persistMessages(messages),
),
```

**方案 B**：ChatProvider 提供 messages 变化通知，ChatPage 监听

**选择方案 A**，改动最小。在 `ChatProvider` 构造函数加一个可选回调 `VoidCallback? onMessagesUpdated`，在 `sendMessage()` finally 中触发。然后在 ChatPage 中：

```dart
// 在 build() 中:
ChangeNotifierProvider(
  create: (_) {
    final provider = ChatProvider(
      topic: widget.topic,
      engine: _engine,
      onMessagesChanged: () {
        if (_conversationId != null) {
          ConversationRepository()
              .updateMessages(_conversationId!, provider.messages);
        }
      },
    );
    return provider;
  },
```

同时需要：
- `ChatProvider` 添加 `onMessagesChanged` 可选参数和调用
- ChatPage 在 build 前初始化 `_conversationId`

**完整步骤**：

1. `ChatProvider` 构造函数加参数：
```dart
class ChatProvider extends ChangeNotifier {
  // ...
  final VoidCallback? _onMessagesChanged;
  
  ChatProvider({
    required this.topic, 
    DialogueEngine? engine, 
    VoidCallback? onMessagesChanged,
  }) : _engine = engine, _onMessagesChanged = onMessagesChanged {
    _addWelcomeMessage();
  }
```

在 `sendMessage()` finally 块中：
```dart
} finally {
      _round++;
      _isThinking = false;
      notifyListeners();
      _onMessagesChanged?.call();
    }
```

2. ChatPage 中：
- 添加 `int? _conversationId;` 字段
- 修改 `Provider` 创建逻辑

---

### Task 7: 在 main.dart 初始化 Repository + ConversationProvider

**Files:**
- Modify: `lib/main.dart`
- Modify: `lib/app.dart`

**Step 1: main() 中初始化 sqflite**

```dart
// lib/main.dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ConversationRepository.initialize();
  runApp(const SocraticApp());
}
```

**Step 2: app.dart 注入 ConversationProvider**

```dart
// lib/app.dart
MultiProvider(
  providers: [
    ChangeNotifierProvider(create: (_) => ConversationProvider()),
  ],
  child: MaterialApp(...),
)
```

---

### Task 8: 测试

**Files:**
- Create: `test/core/models/conversation_test.dart`
- Create: `test/features/history/providers/conversation_provider_test.dart`

**Step 1: Conversation 模型序列化测试**

```dart
test('Conversation toMap/fromMap 往返一致', () {
  final conv = Conversation(
    id: 1,
    topic: '职业发展',
    messages: [
      const ChatMessage(role: MessageRole.ai, content: '你好', round: 0),
      const ChatMessage(role: MessageRole.user, content: '我想聊聊', round: 1),
    ],
    insight: const InsightResult(
      coreInsights: ['重视安全'],
      underlyingValues: ['安全'],
      contradictionsFound: [],
    ),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );

  final map = conv.toMap();
  final restored = Conversation.fromMap(map);

  expect(restored.topic, '职业发展');
  expect(restored.messages.length, 2);
  expect(restored.insight!.coreInsights.first, '重视安全');
});
```

---

### Task 9: 全链路验证

- `flutter analyze lib/ test/` — 零 error/warning
- 启动 App → 选话题 → 对话 3 轮 → 结束 → 返回首页
- 点击历史 → 看到刚才的会话记录 → 点进去看到洞察 → 左滑删除能删

---

### 改动文件汇总

| 操作 | 文件 | 说明 |
|:--|------|------|
| 修改 | `pubspec.yaml` | 添加 sqflite + path 依赖 |
| 修改 | `lib/main.dart` | 初始化 ConversationRepository |
| 修改 | `lib/app.dart` | 注入 ConversationProvider |
| 新建 | `lib/core/models/conversation.dart` | Conversation 数据模型（toMap/fromMap） |
| 新建 | `lib/features/history/engine/conversation_repository.dart` | sqflite CRUD |
| 新建 | `lib/features/history/providers/conversation_provider.dart` | 会话列表状态管理 |
| 新建 | `lib/features/history/widgets/conversation_card.dart` | 历史卡片 |
| 重写 | `lib/features/history/history_page.dart` | 完整历史列表 UI |
| 修改 | `lib/features/chat/providers/chat_provider.dart` | 添加 onMessagesChanged 回调 |
| 修改 | `lib/features/chat/chat_page.dart` | 集成持久化写入 + _conversationId |
| 新建 | `test/core/models/conversation_test.dart` | 序列化测试 |

## 技术决策

| 决策 | 选项 | 选择 | 原因 |
|:--|------|:--:|------|
| 端侧存储 | sqflite / drift / Hive | **sqflite** | 与 Day 5b Go 后端 SQLite schema 自然对齐；SQL 查询灵活；Flutter 社区最成熟的 SQLite 方案 |
| 消息存储粒度 | 逐条 INSERT / JSON 整批 | **JSON 整批** | 无消息检索需求；每批 ~3-5KB；避免高频写入导致的性能问题 |
| 会话 ID | 自增 INTEGER / UUID | **自增 INTEGER** | 本地单用户场景无冲突风险；比 UUID 简洁，与后端 AUTOINCREMENT 一致 |
| Repository 实例化 | 单例 static / 依赖注入 | **单例 static** | 当前只有本地 sqflite 一个数据源，单例足够；Day 6 后端联调时再抽象接口 |
| ChatProvider ↔ Repository 通信 | 回调注入 / event bus / Provider 嵌套 | **回调注入** | 最轻量；ChatProvider 不需要知道 Repository 存在；测试时 mock 回调即可 |
| 收藏置顶 | 独立排序 / 仅标记 | **仅标记** | YAGNI，现阶段收藏只影响星标显示，不做排序干扰 |
