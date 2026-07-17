import 'package:socratic_ai/core/logger.dart';
import 'package:socratic_ai/core/models/dashboard_models.dart';
import 'package:socratic_ai/core/repository/dashboard_repository.dart';

/// Dashboard 状态管理
///
/// 管理大局观面板的全部状态：目标(Goal)、策略(Strategy)、洞察(CrossPattern)。
/// 数据从 [DashboardRepository] 读取，通过 [load()] 从 DB 刷新。
/// 状态变更（完成/暂停/恢复）通过 [toggleGoalStatus] / [toggleStrategy] 写入 DB 后重新加载。
///
/// 分层：只依赖 repository / models / core，不感知 engine 层。
/// 消费方：DashboardPage（唯一），不跨 feature 共享。

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

  Future<void> toggleGoalStatus(int goalId, GoalStatus newStatus) async {
    if (newStatus == GoalStatus.completed) {
      await _repo.completeAllStrategiesForGoal(goalId);
    }
    await _repo.updateGoalStatus(goalId, newStatus);
    await load();
  }

  Future<void> toggleStrategy(int strategyId, bool completed) async {
    await _repo.updateStrategyCompleted(strategyId, completed);
    await load();
  }
}
