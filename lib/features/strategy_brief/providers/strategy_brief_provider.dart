import 'dart:convert';
import 'package:socratic_ai/core/engine/conversation_service.dart';
import 'package:socratic_ai/core/engine/llama_service.dart';
import 'package:socratic_ai/core/engine/strategist_extractor.dart';
import 'package:socratic_ai/core/logger.dart';
import 'package:socratic_ai/core/models/conversation.dart';
import 'package:socratic_ai/core/models/dashboard_models.dart';
import 'package:socratic_ai/core/repository/conversation_repository.dart';
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
  final Set<int> confirmedNewGoals;
  final Set<int> ignoredNewGoals;
  final Set<int> confirmedGoalUpdates;
  final Set<int> ignoredGoalUpdates;
  final Set<int> deletedInsights;

  StrategyBriefState({
    this.status = BriefStatus.loading,
    this.extraction,
    this.existingGoals = const [],
    this.errorMessage,
    this.confirmedNewGoals = const {},
    this.ignoredNewGoals = const {},
    this.confirmedGoalUpdates = const {},
    this.ignoredGoalUpdates = const {},
    this.deletedInsights = const {},
  });
}

class StrategyBriefProvider {
  final Conversation _conversation;
  final DashboardRepository _dashboardRepo = DashboardRepository();
  final ConversationRepository _convRepo = ConversationRepository();

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
    // Check if already extracted
    if (_conversation.extractionJson != null &&
        _conversation.extractionJson!.isNotEmpty) {
      try {
        final json =
            jsonDecode(_conversation.extractionJson!) as Map<String, dynamic>;
        final result = ExtractionResult.fromJson(json);
        final existingGoals = await _dashboardRepo.getAllGoals();

        if (result.hasContent) {
          _state = StrategyBriefState(
            status: BriefStatus.hasContent,
            extraction: result,
            existingGoals: existingGoals,
          );
        } else {
          _state = StrategyBriefState(
            status: BriefStatus.noContent,
            existingGoals: existingGoals,
          );
        }
        _notify();
        return;
      } catch (e) {
        AppLogger.warn(
            'StrategyBriefProvider', '缓存提取结果解析失败，重新提取: $e');
      }
    }

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

        // Auto-update conversation title from extracted goals
        if (result.newGoals.isNotEmpty && _conversation.id != null) {
          final title =
              result.newGoals.map((g) => g.title).take(2).join('、');
          _conversation.topic = title;
          await _convRepo.updateTopic(_conversation.id!, title);
        }
      }

      // Save extraction snapshot to conversation
      if (_conversation.id != null && result != null) {
        _conversation.extractionJson = jsonEncode(result.toJson());
        await _convRepo.updateExtractionJson(
            _conversation.id!, _conversation.extractionJson!);
      }

      // Mark conversation as completed
      if (_conversation.id != null) {
        _conversation.status = 'completed';
        await ConversationService().finishConversation(_conversation.id!, null);
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
    _dashboardRepo.insertGoal(goal);

    final confirmed = {..._state.confirmedNewGoals, index};
    _state = StrategyBriefState(
      status: _state.status,
      extraction: _state.extraction,
      existingGoals: _state.existingGoals,
      errorMessage: _state.errorMessage,
      confirmedNewGoals: confirmed,
      ignoredNewGoals: _state.ignoredNewGoals,
      confirmedGoalUpdates: _state.confirmedGoalUpdates,
      ignoredGoalUpdates: _state.ignoredGoalUpdates,
      deletedInsights: _state.deletedInsights,
    );
    _notify();
  }

  void ignoreNewGoal(int index) {
    final ignored = {..._state.ignoredNewGoals, index};
    _state = StrategyBriefState(
      status: _state.status,
      extraction: _state.extraction,
      existingGoals: _state.existingGoals,
      errorMessage: _state.errorMessage,
      confirmedNewGoals: _state.confirmedNewGoals,
      ignoredNewGoals: ignored,
      confirmedGoalUpdates: _state.confirmedGoalUpdates,
      ignoredGoalUpdates: _state.ignoredGoalUpdates,
      deletedInsights: _state.deletedInsights,
    );
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
    if (existingGoal.title.isNotEmpty && update.newStatus != null) {
      existingGoal.status = update.newStatus!;
      _dashboardRepo.updateGoal(existingGoal);
    }

    final confirmed = {..._state.confirmedGoalUpdates, index};
    _state = StrategyBriefState(
      status: _state.status,
      extraction: _state.extraction,
      existingGoals: _state.existingGoals,
      errorMessage: _state.errorMessage,
      confirmedNewGoals: _state.confirmedNewGoals,
      ignoredNewGoals: _state.ignoredNewGoals,
      confirmedGoalUpdates: confirmed,
      ignoredGoalUpdates: _state.ignoredGoalUpdates,
      deletedInsights: _state.deletedInsights,
    );
    _notify();
  }

  void ignoreGoalUpdate(int index) {
    final ignored = {..._state.ignoredGoalUpdates, index};
    _state = StrategyBriefState(
      status: _state.status,
      extraction: _state.extraction,
      existingGoals: _state.existingGoals,
      errorMessage: _state.errorMessage,
      confirmedNewGoals: _state.confirmedNewGoals,
      ignoredNewGoals: _state.ignoredNewGoals,
      confirmedGoalUpdates: _state.confirmedGoalUpdates,
      ignoredGoalUpdates: ignored,
      deletedInsights: _state.deletedInsights,
    );
    _notify();
  }

  void deleteInsight(int index) {
    final deleted = {..._state.deletedInsights, index};
    _state = StrategyBriefState(
      status: _state.status,
      extraction: _state.extraction,
      existingGoals: _state.existingGoals,
      errorMessage: _state.errorMessage,
      confirmedNewGoals: _state.confirmedNewGoals,
      ignoredNewGoals: _state.ignoredNewGoals,
      confirmedGoalUpdates: _state.confirmedGoalUpdates,
      ignoredGoalUpdates: _state.ignoredGoalUpdates,
      deletedInsights: deleted,
    );
    _notify();
  }
}
