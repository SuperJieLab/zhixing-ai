import 'package:socratic_ai/core/engine/strategist_extractor.dart';
import 'package:socratic_ai/core/logger.dart';
import 'package:socratic_ai/core/models/dashboard_models.dart';
import 'package:socratic_ai/core/repository/dashboard_repository.dart';

class DashboardState {
  final List<Goal> goals;
  final List<Strategy> strategies;
  final List<CrossPattern> crossPatterns;
  final bool isLoading;
  final String? error;

  DashboardState({
    this.goals = const [],
    this.strategies = const [],
    this.crossPatterns = const [],
    this.isLoading = false,
    this.error,
  });

  int get activeGoalCount =>
      goals.where((g) => g.status == GoalStatus.active).length;
  int get pendingStrategyCount => strategies.where((s) => !s.completed).length;
  int get patternCount => crossPatterns.length;

  DashboardState copyWith({
    List<Goal>? goals,
    List<Strategy>? strategies,
    List<CrossPattern>? crossPatterns,
    bool? isLoading,
    String? error,
  }) {
    return DashboardState(
      goals: goals ?? this.goals,
      strategies: strategies ?? this.strategies,
      crossPatterns: crossPatterns ?? this.crossPatterns,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

class DashboardProvider {
  final DashboardRepository _repo = DashboardRepository();

  DashboardState _state = DashboardState();
  DashboardState get state => _state;

  final List<void Function(DashboardState)> _listeners = [];

  void addListener(void Function(DashboardState) listener) {
    _listeners.add(listener);
  }

  void removeListener(void Function(DashboardState) listener) {
    _listeners.remove(listener);
  }

  void _notify() {
    for (final listener in _listeners) {
      listener(_state);
    }
  }

  Future<void> load() async {
    _state = _state.copyWith(isLoading: true);
    _notify();

    try {
      final goals = await _repo.getAllGoals();
      final strategies = await _repo.getAllStrategies();
      final patterns = await _repo.getAllCrossPatterns();

      _state = _state.copyWith(
        goals: goals,
        strategies: strategies,
        crossPatterns: patterns,
        isLoading: false,
      );
    } catch (e) {
      AppLogger.error('DashboardProvider', '加载失败', e);
      _state = _state.copyWith(isLoading: false, error: e.toString());
    }
    _notify();
  }

  Future<void> merge(ExtractionResult result) async {
    if (!result.hasContent) return;

    // 1) 合并新 goals（同名 goal 自动合并 sourceConvIds）
    for (final newGoal in result.newGoals) {
      final existing = await _repo.getGoalByTitle(newGoal.title);
      if (existing != null) {
        final mergedIds = {...existing.sourceConvIds, ...newGoal.sourceConvIds};
        existing.sourceConvIds = mergedIds.toList();
        existing.updatedAt = DateTime.now();
        await _repo.updateGoal(existing);
      } else {
        await _repo.insertGoal(newGoal);
      }
    }

    // 2) 处理 goal updates
    for (final update in result.goalUpdates) {
      final existing = await _repo.getGoalByTitle(update.goalTitle);
      if (existing != null) {
        if (update.newStatus != null) existing.status = update.newStatus!;
        if (update.newNotes != null) existing.notes = update.newNotes;
        existing.updatedAt = DateTime.now();
        await _repo.updateGoal(existing);
      }
    }

    // 3) 插入 strategies（按 goal_title 关联 goal）
    final allGoals = await _repo.getAllGoals();
    for (final strategy in result.strategies) {
      // 找到关联的 goal（如果没有匹配的 goal，跳过该 strategy）
      final matchedGoal = allGoals.cast<Goal?>().firstWhere(
            (g) => g != null && g.title.isNotEmpty,
            orElse: () => null,
          );
      if (matchedGoal != null) {
        strategy.goalId = matchedGoal.id ?? 0;
        await _repo.insertStrategy(strategy);
      } else {
        AppLogger.warn('DashboardProvider',
            '策略「${strategy.description}」无关联目标，跳过');
      }
    }

    // 4) 合并 cross patterns
    for (final pattern in result.crossPatterns) {
      final existing = await _repo.getCrossPatternByLabel(pattern.label);
      if (existing != null) {
        existing.frequency += 1;
        existing.detectedAt = DateTime.now();
        await _repo.updateCrossPattern(existing);
      } else {
        await _repo.insertCrossPattern(pattern);
      }
    }

    await load();
  }
}
