import 'package:sqflite/sqflite.dart';
import 'package:zhixing_ai/core/models/dashboard_models.dart';
import 'package:zhixing_ai/core/repository/conversation_repository.dart';

/// 首页数据仓库（sqflite）
///
/// 负责 goals / strategies / cross_patterns 三张表的 CRUD。
/// 复用 [ConversationRepository] 的 DB 实例（同一 sqflite 文件）。
/// 被 DashboardProvider 和 StrategyBriefProvider 两个 feature 共享。

class DashboardRepository {
  static Future<Database> _db() async {
    final db = ConversationRepository.database;
    if (db == null) throw StateError('ConversationRepository 未初始化');
    return db;
  }

  // ================================================================
  // Goals
  // ================================================================

  Future<int> insertGoal(Goal goal) async {
    final db = await _db();
    return db.insert('goals', goal.toMap());
  }

  Future<List<Goal>> getAllGoals() async {
    final db = await _db();
    final rows = await db.query('goals', orderBy: 'created_at DESC');
    return rows.map((row) => Goal.fromMap(row)).toList();
  }

  Future<List<Goal>> getActiveGoals() async {
    final db = await _db();
    final rows = await db.query('goals',
        where: 'status = ?', whereArgs: ['active'],
        orderBy: 'priority ASC');
    return rows.map((row) => Goal.fromMap(row)).toList();
  }

  Future<void> updateGoal(Goal goal) async {
    final db = await _db();
    await db.update('goals', goal.toMap(),
        where: 'id = ?', whereArgs: [goal.id]);
  }

  Future<void> updateGoalStatus(int goalId, GoalStatus status) async {
    final db = await _db();
    await db.update('goals', {
      'status': status.name,
      'updated_at': DateTime.now().toIso8601String(),
    }, where: 'id = ?', whereArgs: [goalId]);
  }

  // ================================================================
  // Strategies
  // ================================================================

  Future<int> insertStrategy(Strategy strategy) async {
    final db = await _db();
    return db.insert('strategies', strategy.toMap());
  }

  Future<List<Strategy>> getAllStrategies() async {
    final db = await _db();
    final rows = await db.query('strategies', orderBy: 'created_at DESC');
    return rows.map((row) => Strategy.fromMap(row)).toList();
  }

  Future<void> updateStrategyCompleted(int strategyId, bool completed) async {
    final db = await _db();
    await db.update('strategies', {'completed': completed ? 1 : 0},
        where: 'id = ?', whereArgs: [strategyId]);
  }

  Future<void> completeAllStrategiesForGoal(int goalId) async {
    final db = await _db();
    await db.update('strategies', {'completed': 1},
        where: 'goal_id = ?', whereArgs: [goalId]);
  }

  // ================================================================
  // Cross Patterns
  // ================================================================

  Future<int> insertCrossPattern(CrossPattern pattern) async {
    final db = await _db();
    return db.insert('cross_patterns', pattern.toMap());
  }

  Future<List<CrossPattern>> getAllCrossPatterns() async {
    final db = await _db();
    final rows =
        await db.query('cross_patterns', orderBy: 'detected_at DESC');
    return rows.map((row) => CrossPattern.fromMap(row)).toList();
  }

  Future<CrossPattern?> getCrossPatternByLabel(String label) async {
    final db = await _db();
    final rows = await db.query('cross_patterns',
        where: 'label = ?', whereArgs: [label]);
    if (rows.isEmpty) return null;
    return CrossPattern.fromMap(rows.first);
  }

  Future<void> updateCrossPattern(CrossPattern pattern) async {
    final db = await _db();
    await db.update('cross_patterns', pattern.toMap(),
        where: 'id = ?', whereArgs: [pattern.id]);
  }
}
