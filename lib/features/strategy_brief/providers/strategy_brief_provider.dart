import 'dart:convert';
import 'package:zhixing_ai/core/data/conversation_service.dart';
import 'package:zhixing_ai/core/model_gateway.dart';
import 'package:zhixing_ai/core/logger.dart';
import 'package:zhixing_ai/core/data/models/conversation.dart';
import 'package:zhixing_ai/core/data/models/dashboard_models.dart';
import 'package:zhixing_ai/core/data/repository/dashboard_repository.dart';
import 'package:zhixing_ai/features/strategy_brief/engine/strategist_extractor.dart';
import 'package:zhixing_ai/features/strategy_brief/models/extraction_result.dart';

/// 对话提取 & 确认状态管理
///
/// 管理 StrategyBriefPage 的完整流程：
///   1. [extract] → 加载缓存 或 调 LLM 提取目标/策略/洞察
///   2. 提取结果自动保存到 conversation.extractionJson（防重复提取）
///   3. 用户确认/忽略 → 写入 DB（goal/strategy）或缓存状态（_c_ng 等标记）
///   4. 确认状态持久化到 extraction_json，再次进入时自动恢复
///
/// 数据流：Extractor → extraction_json 缓存 → 用户确认 → Dashboard DB
/// 分层：依赖 engine + repository + models，不感知 page/widget 层。

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

  StrategyBriefState copyWith({
    BriefStatus? status,
    ExtractionResult? extraction,
    List<Goal>? existingGoals,
    String? errorMessage,
    Set<int>? confirmedNewGoals,
    Set<int>? ignoredNewGoals,
    Set<int>? confirmedGoalUpdates,
    Set<int>? ignoredGoalUpdates,
    Set<int>? deletedInsights,
  }) {
    return StrategyBriefState(
      status: status ?? this.status,
      extraction: extraction ?? this.extraction,
      existingGoals: existingGoals ?? this.existingGoals,
      errorMessage: errorMessage ?? this.errorMessage,
      confirmedNewGoals: confirmedNewGoals ?? this.confirmedNewGoals,
      ignoredNewGoals: ignoredNewGoals ?? this.ignoredNewGoals,
      confirmedGoalUpdates: confirmedGoalUpdates ?? this.confirmedGoalUpdates,
      ignoredGoalUpdates: ignoredGoalUpdates ?? this.ignoredGoalUpdates,
      deletedInsights: deletedInsights ?? this.deletedInsights,
    );
  }
}

class StrategyBriefProvider {
  final Conversation _conversation;
  final ModelGateway _gateway;
  final DashboardRepository _dashboardRepo;
  final ConversationService _convService;

  StrategyBriefState _state = StrategyBriefState();
  StrategyBriefState get state => _state;

  final List<void Function(StrategyBriefState)> _listeners = [];

  /// [gateway] 由页面经 Provider 树注入（composition root 构造的唯一实例）；
  /// 提取的后端模式跟随全局配置（云端 / 本地），本类不感知。
  ///
  /// [dashboardRepo] / [conversationService] 缺省用真实实现（sqflite）；测试
  /// 注入 fake 子类即可覆盖「提取 → 落库 → 确认」全链路——此前二者硬编码，
  /// 导致该链路在无 DB 的测试环境下完全不可验证。
  StrategyBriefProvider(
    this._conversation, {
    required ModelGateway gateway,
    DashboardRepository? dashboardRepo,
    ConversationService? conversationService,
  })  : _gateway = gateway, // ignore: prefer_initializing_formals
        _dashboardRepo = dashboardRepo ?? DashboardRepository(),
        _convService = conversationService ?? ConversationService();

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
    if (_conversation.extractionJson != null &&
        _conversation.extractionJson!.isNotEmpty) {
      try {
        final json =
            jsonDecode(_conversation.extractionJson!) as Map<String, dynamic>;

        if (json['extracted'] == false) {
          _state = StrategyBriefState(
            status: BriefStatus.noContent,
            existingGoals: await _dashboardRepo.getAllGoals(),
          );
          _notify();
          return;
        }

        final result = ExtractionResult.fromJson(json);
        final existingGoals = await _dashboardRepo.getAllGoals();

        final confirmedNew = _restoreIndexSet(json, '_c_ng');
        final ignoredNew = _restoreIndexSet(json, '_i_ng');
        final confirmedUp = _restoreIndexSet(json, '_c_gu');
        final ignoredUp = _restoreIndexSet(json, '_i_gu');
        final deletedIns = _restoreIndexSet(json, '_d_ip');

        if (result.hasContent) {
          _state = StrategyBriefState(
            status: BriefStatus.hasContent,
            extraction: result,
            existingGoals: existingGoals,
            confirmedNewGoals: confirmedNew,
            ignoredNewGoals: ignoredNew,
            confirmedGoalUpdates: confirmedUp,
            ignoredGoalUpdates: ignoredUp,
            deletedInsights: deletedIns,
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

      final extractor = StrategistExtractor(_gateway);
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

        if (result.newGoals.isNotEmpty && _conversation.id != null) {
          final title =
              result.newGoals.map((g) => g.title).take(2).join('、');
          _conversation.topic = title;
          await _convService.updateTopic(_conversation.id!, title);
        }

        await _persistCrossPatterns(result);
      }

      await _saveExtractionAndComplete(result);
    } catch (e) {
      AppLogger.error('StrategyBriefProvider', '提取失败', e);
      _state = StrategyBriefState(
        status: BriefStatus.error,
        errorMessage: e.toString(),
      );
    }
    _notify();
  }

  Future<void> _persistCrossPatterns(ExtractionResult result) async {
    for (final pattern in result.crossPatterns) {
      final existing =
          await _dashboardRepo.getCrossPatternByLabel(pattern.label);
      if (existing != null) {
        existing.frequency += 1;
        existing.detectedAt = DateTime.now();
        await _dashboardRepo.updateCrossPattern(existing);
      } else {
        await _dashboardRepo.insertCrossPattern(pattern);
      }
    }
  }

  Future<void> _saveExtractionAndComplete(ExtractionResult? result) async {
    if (_conversation.id == null) return;

    final data = result?.toJson() ?? {'extracted': false};
    final json = jsonEncode(data);
    _conversation.extractionJson = json;
    await _convService.updateExtractionJson(_conversation.id!, json);

    _conversation.status = 'completed';
    await _convService.finishConversation(_conversation.id!);
  }

  Future<void> _saveStateToCache() async {
    if (_conversation.id == null || _conversation.extractionJson == null) {
      return;
    }
    try {
      final json =
          jsonDecode(_conversation.extractionJson!) as Map<String, dynamic>;
      json['_c_ng'] = _state.confirmedNewGoals.toList();
      json['_i_ng'] = _state.ignoredNewGoals.toList();
      json['_c_gu'] = _state.confirmedGoalUpdates.toList();
      json['_i_gu'] = _state.ignoredGoalUpdates.toList();
      json['_d_ip'] = _state.deletedInsights.toList();

      final updated = jsonEncode(json);
      _conversation.extractionJson = updated;
      await _convService.updateExtractionJson(_conversation.id!, updated);
    } catch (e) {
      AppLogger.warn('StrategyBriefProvider', '保存确认状态失败: $e');
    }
  }

  Set<int> _restoreIndexSet(Map<String, dynamic> json, String key) {
    final list = json[key] as List<dynamic>?;
    if (list == null) return {};
    return list.map((e) => e as int).toSet();
  }

  /// 目标详情页数据源：该目标在库中的真实策略
  /// （修复 relatedStrategies 恒空的死表达式，StrategyDetailPage 不再永远「暂无策略」）。
  Future<List<Strategy>> strategiesForGoal(Goal goal) async {
    if (goal.id == null) return const [];
    final all = await _dashboardRepo.getAllStrategies();
    return all.where((s) => s.goalId == goal.id).toList();
  }

  void confirmNewGoal(int index) {
    final goal = _state.extraction?.newGoals[index];
    if (goal == null) return;
    goal.status = GoalStatus.active;
    _dashboardRepo.insertGoal(goal).then((goalId) {
      _insertStrategiesForGoal(goal.title, goalId);
    });

    _mark(confirmedNewGoal: index);
  }

  Future<void> _insertStrategiesForGoal(
      String goalTitle, int goalId) async {
    final strategies =
        _state.extraction?.strategies.where((s) => s.goalTitle == goalTitle);
    if (strategies == null) return;

    for (final strategy in strategies) {
      strategy.goalId = goalId;
      await _dashboardRepo.insertStrategy(strategy);
    }
  }

  void ignoreNewGoal(int index) {
    _mark(ignoredNewGoal: index);
  }

  void confirmGoalUpdate(int index) {
    final update = _state.extraction?.goalUpdates[index];
    if (update == null) return;

    final existingGoal = matchGoal(_state.existingGoals,
        goalId: update.goalId, goalTitle: update.goalTitle);
    if (existingGoal != null && update.newStatus != null) {
      existingGoal.status = update.newStatus!;
      _dashboardRepo.updateGoal(existingGoal);

      if (update.newStatus == GoalStatus.completed) {
        _dashboardRepo.completeAllStrategiesForGoal(existingGoal.id!);
      }
    }

    _mark(confirmedGoalUpdate: index);
  }

  void ignoreGoalUpdate(int index) {
    _mark(ignoredGoalUpdate: index);
  }

  void deleteInsight(int index) {
    _mark(deletedInsight: index);
  }

  /// 标记位并入（显式字段名，无字符串键分发）：改完即通知 + 落缓存。
  ///
  /// 五类标记互斥使用——每次只传一个 index，其余为 null 表示「该集合不动」。
  void _mark({
    int? confirmedNewGoal,
    int? ignoredNewGoal,
    int? confirmedGoalUpdate,
    int? ignoredGoalUpdate,
    int? deletedInsight,
  }) {
    Set<int> merge(Set<int> current, int? index) => {...current, ?index};

    _state = _state.copyWith(
      confirmedNewGoals: merge(_state.confirmedNewGoals, confirmedNewGoal),
      ignoredNewGoals: merge(_state.ignoredNewGoals, ignoredNewGoal),
      confirmedGoalUpdates:
          merge(_state.confirmedGoalUpdates, confirmedGoalUpdate),
      ignoredGoalUpdates: merge(_state.ignoredGoalUpdates, ignoredGoalUpdate),
      deletedInsights: merge(_state.deletedInsights, deletedInsight),
    );
    _notify();
    _saveStateToCache();
  }
}

/// 在已有目标中定位提取结果关联的目标：优先按 [goalId]（提取契约 v2 起
/// LLM 回传），回退按 [goalTitle] 精确匹配。都未命中返回 null。
///
/// 纯函数（无 DB 依赖）以便单测；title 回退兼容旧缓存与模型未回传 id 的情况，
/// 修复「重名目标时 firstWhere 恒命中第一条」的误配。
Goal? matchGoal(
  List<Goal> goals, {
  int? goalId,
  String? goalTitle,
}) {
  if (goalId != null) {
    for (final g in goals) {
      if (g.id == goalId) return g;
    }
  }
  if (goalTitle != null && goalTitle.isNotEmpty) {
    for (final g in goals) {
      if (g.title == goalTitle) return g;
    }
  }
  return null;
}
