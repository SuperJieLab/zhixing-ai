import 'package:socratic_ai/core/engine/llama_service.dart';
import 'package:socratic_ai/core/engine/strategist_extractor.dart';
import 'package:socratic_ai/core/logger.dart';
import 'package:socratic_ai/core/models/conversation.dart';
import 'package:socratic_ai/core/models/dashboard_models.dart';
import 'package:socratic_ai/core/repository/dashboard_repository.dart';

enum BriefStatus {
  loading,
  extracting,
  noContent,
  hasContent,
  error,
}

class StrategyBriefState {
  final BriefStatus status;
  final ExtractionResult? extraction;
  final List<Goal> existingGoals;
  final String? errorMessage;

  StrategyBriefState({
    this.status = BriefStatus.loading,
    this.extraction,
    this.existingGoals = const [],
    this.errorMessage,
  });
}

class StrategyBriefProvider {
  final Conversation _conversation;
  final DashboardRepository _dashboardRepo = DashboardRepository();

  StrategyBriefState _state = StrategyBriefState();
  StrategyBriefState get state => _state;

  final List<void Function(StrategyBriefState)> _listeners = [];

  StrategyBriefProvider(this._conversation);

  void addListener(void Function(StrategyBriefState) listener) {
    _listeners.add(listener);
  }

  void removeListener(void Function(StrategyBriefState) listener) {
    _listeners.remove(listener);
  }

  void _notify() {
    for (final listener in _listeners) {
      listener(_state);
    }
  }

  Future<void> extract() async {
    _state = StrategyBriefState(status: BriefStatus.extracting);
    _notify();

    try {
      final existingGoals = await _dashboardRepo.getAllGoals();
      _state = StrategyBriefState(
        status: BriefStatus.extracting,
        existingGoals: existingGoals,
      );
      _notify();

      final engine = LlamaService.instance.ensureReady();
      final llmEngine = await engine;
      final extractor = StrategistExtractor(llmEngine);
      final result = await extractor.extract(
        conversation: _conversation,
        existingGoals: existingGoals,
      );

      if (result == null || !result.hasContent) {
        _state = StrategyBriefState(
          status: BriefStatus.noContent,
          existingGoals: existingGoals,
        );
      } else {
        _state = StrategyBriefState(
          status: BriefStatus.hasContent,
          extraction: result,
          existingGoals: existingGoals,
        );
      }
    } catch (e) {
      AppLogger.error('StrategyBriefProvider', '提取失败', e);
      _state = StrategyBriefState(
        status: BriefStatus.error,
        errorMessage: e.toString(),
      );
    }
    _notify();
  }

  void confirmNewGoal(int index) {
    final goal = _state.extraction?.newGoals[index];
    if (goal == null) return;
    goal.status = GoalStatus.active;
    _dashboardRepo.updateGoal(goal);
    _state.extraction!.newGoals.removeAt(index);
    _reevaluateStatus();
    _notify();
  }

  void ignoreNewGoal(int index) {
    _state.extraction?.newGoals.removeAt(index);
    _reevaluateStatus();
    _notify();
  }

  void confirmGoalUpdate(int index) {
    final update = _state.extraction?.goalUpdates[index];
    if (update == null) return;

    final existingGoal = _state.existingGoals.firstWhere(
      (g) => g.title == update.goalTitle,
      orElse: () => Goal(
          title: '',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now()),
    );
    if (existingGoal.title.isEmpty) return;

    if (update.newStatus != null) {
      existingGoal.status = update.newStatus!;
      _dashboardRepo.updateGoal(existingGoal);
    }

    _state.extraction!.goalUpdates.removeAt(index);
    _reevaluateStatus();
    _notify();
  }

  void ignoreGoalUpdate(int index) {
    _state.extraction?.goalUpdates.removeAt(index);
    _reevaluateStatus();
    _notify();
  }

  void deleteInsight(int index) {
    _state.extraction?.crossPatterns.removeAt(index);
    _reevaluateStatus();
    _notify();
  }

  void _reevaluateStatus() {
    final extraction = _state.extraction;
    if (extraction == null || !extraction.hasContent) {
      _state = StrategyBriefState(
        status: BriefStatus.noContent,
        existingGoals: _state.existingGoals,
      );
    }
  }
}
