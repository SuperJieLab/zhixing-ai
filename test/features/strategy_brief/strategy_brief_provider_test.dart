import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixing_ai/core/data/conversation_service.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/data/models/conversation.dart';
import 'package:zhixing_ai/core/data/models/dashboard_models.dart';
import 'package:zhixing_ai/core/data/repository/dashboard_repository.dart';
import 'package:zhixing_ai/features/strategy_brief/providers/strategy_brief_provider.dart';

import '../../support/fake_llm.dart';

/// StrategyBriefProvider：**提取 → 落库 → 用户确认**全链路
///
/// 此前 DashboardRepository / ConversationService 在 provider 内硬编码，
/// 无 sqflite 的测试环境下整条链路不可验证（只有 ChatPage 的导航用例能
/// 覆盖到「进入了这个页面」）。现在二者可注入，这里用 fake 子类记录调用，
/// 断言真实的落库语义：写 extraction_json、标记 completed、目标/策略/洞察
/// 入库与确认状态回写。

// ================================================================
// Fakes：只记录调用，不触 DB
// ================================================================

class _FakeDashboardRepository extends DashboardRepository {
  _FakeDashboardRepository({this.goals = const []});

  List<Goal> goals;

  /// 置为非 null 时 `getAllGoals` 抛错（模拟 DB 不可用）。
  Object? throwOnGetAllGoals;

  /// 置为非 null 时 `getCrossPatternByLabel` 命中（模拟库中已有同名洞察）。
  CrossPattern? existingPattern;

  final List<Goal> insertedGoals = [];
  final List<Strategy> insertedStrategies = [];
  final List<CrossPattern> insertedPatterns = [];
  final List<CrossPattern> updatedPatterns = [];
  final List<Goal> updatedGoals = [];
  final List<int> completedStrategyGoalIds = [];
  int getAllGoalsCalls = 0;

  @override
  Future<List<Goal>> getAllGoals() async {
    getAllGoalsCalls++;
    if (throwOnGetAllGoals != null) throw throwOnGetAllGoals!;
    return List.of(goals);
  }

  @override
  Future<List<Strategy>> getAllStrategies() async => const [];

  @override
  Future<int> insertGoal(Goal goal) async {
    insertedGoals.add(goal);
    return 42; // 约定：新目标落库后拿到 id=42
  }

  @override
  Future<int> insertStrategy(Strategy strategy) async {
    insertedStrategies.add(strategy);
    return insertedStrategies.length;
  }

  @override
  Future<CrossPattern?> getCrossPatternByLabel(String label) async =>
      existingPattern;

  @override
  Future<int> insertCrossPattern(CrossPattern pattern) async {
    insertedPatterns.add(pattern);
    return insertedPatterns.length;
  }

  @override
  Future<void> updateCrossPattern(CrossPattern pattern) async =>
      updatedPatterns.add(pattern);

  @override
  Future<void> updateGoal(Goal goal) async => updatedGoals.add(goal);

  @override
  Future<void> completeAllStrategiesForGoal(int goalId) async =>
      completedStrategyGoalIds.add(goalId);
}

class _FakeConversationService extends ConversationService {
  final List<String> topicUpdates = [];
  final List<String> extractionWrites = [];
  final List<int> finished = [];

  @override
  Future<void> updateTopic(int conversationId, String topic) async =>
      topicUpdates.add(topic);

  @override
  Future<void> updateExtractionJson(
      int conversationId, String extractionJson) async =>
      extractionWrites.add(extractionJson);

  @override
  Future<void> finishConversation(int conversationId) async =>
      finished.add(conversationId);
}

// ================================================================
// 夹具
// ================================================================

/// 含 2 条用户消息（提取门槛：用户消息 < 2 条即跳过）。
Conversation _conversation({int? id = 1, String? extractionJson}) {
  final now = DateTime(2026, 9, 15);
  return Conversation(
    id: id,
    topic: '职业发展',
    messages: [
      ChatMessage(role: MessageRole.ai, content: '你好，想聊点什么？', round: 0),
      ChatMessage(role: MessageRole.user, content: '我最近在准备跳槽', round: 1),
      ChatMessage(role: MessageRole.ai, content: '想聊聊哪方面？', round: 1),
      ChatMessage(role: MessageRole.user, content: '面试准备', round: 2),
      ChatMessage(role: MessageRole.ai, content: '具体说说看', round: 2),
    ],
    extractionJson: extractionJson,
    createdAt: now,
    updatedAt: now,
  );
}

/// 一份「有内容」的提取结果：1 新目标 + 1 状态更新建议 + 1 策略 + 1 洞察。
Map<String, dynamic> _payload() => {
      'relevant': true,
      'new_goals': [
        {
          'title': '准备面试',
          'category': 'career',
          'priority': 1,
          'deadline': '2026-10-01',
        },
      ],
      'goal_updates': [
        {
          'goal_id': 7,
          'goal_title': '每周健身三次',
          'suggested_status': 'completed',
          'reason': '已连续打卡',
        },
      ],
      'strategies': [
        {
          'goal_title': '准备面试',
          'description': '每天刷两道算法题',
          'type': 'selfAction',
          'next_step': '今晚先做一道',
        },
      ],
      'cross_patterns': [
        {'label': '临期冲刺', 'description': '总在截止前才动手'},
      ],
    };

Goal _existingGoal() {
  final now = DateTime(2026, 9, 15);
  return Goal(
    id: 7,
    title: '每周健身三次',
    category: GoalCategory.health,
    status: GoalStatus.active,
    priority: 2,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  late _FakeDashboardRepository repo;
  late _FakeConversationService conv;
  late FakeLlm llm;

  StrategyBriefProvider build(Conversation conversation) => StrategyBriefProvider(
        conversation,
        gateway: FakeGateway(llm: llm),
        dashboardRepo: repo,
        conversationService: conv,
      );

  setUp(() {
    repo = _FakeDashboardRepository();
    conv = _FakeConversationService();
    llm = FakeLlm();
  });

  // ================================================================
  // 提取
  // ================================================================
  group('extract：提取与落库', () {
    test('成功：写 extraction_json、更新话题、洞察入库、标记 completed', () async {
      llm.onAskJson = (_, _) async => _payload();
      final conversation = _conversation();
      final provider = build(conversation);

      await provider.extract();

      expect(provider.state.status, BriefStatus.hasContent);
      expect(provider.state.extraction!.newGoals.single.title, '准备面试');

      // 落库：extraction_json（含提取结果） + 收尾
      expect(conv.extractionWrites, hasLength(1));
      final written = jsonDecode(conv.extractionWrites.single) as Map;
      expect(written['new_goals'], hasLength(1));
      expect(conv.finished, [1]);
      expect(conversation.status, 'completed');

      // 新目标标题回写话题
      expect(conv.topicUpdates, ['准备面试']);

      // 提取阶段不写 Dashboard 任何表：目标/策略/洞察一律待用户确认
      // （洞察曾例外——提取即入库，导致页面上的「删除」删不掉、首页照旧显示）
      expect(repo.insertedGoals, isEmpty);
      expect(repo.insertedStrategies, isEmpty);
      expect(repo.insertedPatterns, isEmpty);
      expect(repo.updatedPatterns, isEmpty);
    });

    test('用户消息不足 2 条：不调 LLM，但仍写 extracted:false 并收尾', () async {
      llm.onAskJson = (_, _) async => _payload();
      final conversation = _conversation();
      conversation.messages = [
        ChatMessage(role: MessageRole.user, content: '随便聊聊', round: 1),
      ];
      final provider = build(conversation);

      await provider.extract();

      expect(llm.askJsonCalls, isEmpty); // 过短直接跳过，不花一次推理
      expect(provider.state.status, BriefStatus.noContent);
      expect(jsonDecode(conv.extractionWrites.single)['extracted'], false);
      expect(conv.finished, [1]);
    });

    test('LLM 抛错：引擎吞掉 → 按无内容收尾，不冒泡成 error 态', () async {
      llm.onAskJson = (_, _) async => throw StateError('上游 500');
      final conversation = _conversation();
      final provider = build(conversation);

      await provider.extract();

      expect(provider.state.status, BriefStatus.noContent);
      expect(jsonDecode(conv.extractionWrites.single)['extracted'], false);
      expect(conv.finished, [1]); // 会话仍被正常收尾
    });

    test('读库失败：进入 error 态，且不写 extraction_json、不收尾', () async {
      llm.onAskJson = (_, _) async => _payload();
      repo.throwOnGetAllGoals = StateError('ConversationRepository 未初始化');
      final provider = build(_conversation());

      await provider.extract();

      expect(provider.state.status, BriefStatus.error);
      expect(provider.state.errorMessage, contains('未初始化'));
      expect(conv.extractionWrites, isEmpty);
      expect(conv.finished, isEmpty);
    });
  });

  // ================================================================
  // 缓存命中
  // ================================================================
  group('extract：命中 extraction_json 缓存', () {
    test('已有提取结果：直接恢复，不再调 LLM、不重复落库', () async {
      final cached = jsonEncode(_payload());
      final provider = build(_conversation(extractionJson: cached));

      await provider.extract();

      expect(llm.askJsonCalls, isEmpty);
      expect(provider.state.status, BriefStatus.hasContent);
      expect(provider.state.extraction!.crossPatterns.single.label, '临期冲刺');
      // 早退路径不写库：避免重复提取 + 重复落库
      expect(conv.extractionWrites, isEmpty);
      expect(repo.insertedPatterns, isEmpty);
    });

    test('缓存为 extracted:false：恢复为无内容态，且不再提取', () async {
      final provider = build(
        _conversation(extractionJson: jsonEncode({'extracted': false})),
      );

      await provider.extract();

      expect(llm.askJsonCalls, isEmpty);
      expect(provider.state.status, BriefStatus.noContent);
    });

    test('缓存损坏（非法 JSON）：回落为重新提取', () async {
      llm.onAskJson = (_, _) async => _payload();
      final provider = build(_conversation(extractionJson: '{坏 JSON'));

      await provider.extract();

      expect(llm.askJsonCalls, hasLength(1));
      expect(provider.state.status, BriefStatus.hasContent);
    });
  });

  // ================================================================
  // 用户确认 → 落库
  // ================================================================
  group('确认动作 → 落库', () {
    /// 提取一次，拿到「有内容」状态（new_goals[0] 关联 1 条策略，目标 id=7）。
    Future<StrategyBriefProvider> extracted() async {
      repo = _FakeDashboardRepository(goals: [_existingGoal()]);
      llm.onAskJson = (_, _) async => _payload();
      final provider = build(_conversation());
      await provider.extract();
      return provider;
    }

    test('确认新目标：insertGoal（置 active）+ 策略回填 goalId 后入库', () async {
      final provider = await extracted();

      provider.confirmNewGoal(0);
      await pumpEventQueue();

      final goal = repo.insertedGoals.single;
      expect(goal.title, '准备面试');
      expect(goal.status, GoalStatus.active); // 确认即生效
      expect(repo.insertedStrategies.single.goalId, 42); // 回填新目标 id
      expect(provider.state.confirmedNewGoals, {0});
    });

    test('忽略新目标：目标与策略都不落库', () async {
      final provider = await extracted();

      provider.ignoreNewGoal(0);
      await pumpEventQueue();

      expect(repo.insertedGoals, isEmpty);
      expect(repo.insertedStrategies, isEmpty);
      expect(provider.state.ignoredNewGoals, {0});
    });

    test('确认目标更新为 completed：updateGoal + 完结该目标全部策略', () async {
      final provider = await extracted();

      provider.confirmGoalUpdate(0);
      await pumpEventQueue();

      expect(repo.updatedGoals.single.id, 7);
      expect(repo.updatedGoals.single.status, GoalStatus.completed);
      expect(repo.completedStrategyGoalIds, [7]);
    });

    test('确认状态回写 extraction_json（_c_ng 标记），便于再次进入恢复',
        () async {
      final provider = await extracted();
      conv.extractionWrites.clear();

      provider.confirmNewGoal(0);
      await pumpEventQueue();

      final restored = jsonDecode(conv.extractionWrites.single) as Map;
      expect(restored['_c_ng'], [0]);
    });

    test('确认洞察：新建入库，来源会话计入 sourceConvIds（frequency 随之）',
        () async {
      final provider = await extracted();

      provider.confirmInsight(0);
      await pumpEventQueue();

      final pattern = repo.insertedPatterns.single;
      expect(pattern.label, '临期冲刺');
      expect(pattern.sourceConvIds, [1]); // 本会话 id=1
      expect(pattern.frequency, 1);
      expect(provider.state.confirmedInsights, {0});
    });

    test('确认洞察（库中已有同名）：并入本次会话来源，不新建', () async {
      final provider = await extracted();
      repo.existingPattern = CrossPattern(
        id: 9,
        label: '临期冲刺',
        description: '旧描述',
        sourceConvIds: const [3],
        frequency: 1,
        detectedAt: DateTime(2026, 9, 1),
      );

      provider.confirmInsight(0);
      await pumpEventQueue();

      expect(repo.insertedPatterns, isEmpty);
      final updated = repo.updatedPatterns.single;
      expect(updated.sourceConvIds, [3, 1]);
      expect(updated.frequency, 2); // = 来源会话数
    });

    test('忽略洞察：不落库，仅本地标记（首页不会出现）', () async {
      final provider = await extracted();

      provider.ignoreInsight(0);
      await pumpEventQueue();

      expect(repo.insertedPatterns, isEmpty);
      expect(repo.updatedPatterns, isEmpty);
      expect(provider.state.ignoredInsights, {0});
    });

    test('洞察确认状态回写 extraction_json（_c_ip / _i_ip），再次进入可恢复',
        () async {
      final provider = await extracted();
      conv.extractionWrites.clear();

      provider.confirmInsight(0);
      await pumpEventQueue();

      final restored = jsonDecode(conv.extractionWrites.single) as Map;
      expect(restored['_c_ip'], [0]);
      expect(restored['_i_ip'], isEmpty);
    });
  });
}
