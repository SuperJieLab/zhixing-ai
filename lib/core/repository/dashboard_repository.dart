import 'package:sqflite/sqflite.dart';
import 'package:socratic_ai/core/models/dashboard_models.dart';
import 'package:socratic_ai/core/repository/conversation_repository.dart';

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

  Future<Goal?> getGoalByTitle(String title) async {
    final db = await _db();
    final rows = await db.query('goals',
        where: 'title = ?', whereArgs: [title]);
    if (rows.isEmpty) return null;
    return Goal.fromMap(rows.first);
  }

  Future<void> updateGoal(Goal goal) async {
    final db = await _db();
    await db.update('goals', goal.toMap(),
        where: 'id = ?', whereArgs: [goal.id]);
  }

  // ================================================================
  // Strategies
  // ================================================================

  Future<int> insertStrategy(Strategy strategy) async {
    final db = await _db();
    return db.insert('strategies', strategy.toMap());
  }

  Future<List<Strategy>> getStrategiesByGoal(int goalId) async {
    final db = await _db();
    final rows = await db.query('strategies',
        where: 'goal_id = ?', whereArgs: [goalId], orderBy: 'created_at ASC');
    return rows.map((row) => Strategy.fromMap(row)).toList();
  }

  Future<List<Strategy>> getAllStrategies() async {
    final db = await _db();
    final rows = await db.query('strategies', orderBy: 'created_at DESC');
    return rows.map((row) => Strategy.fromMap(row)).toList();
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
