import 'package:flutter/material.dart';
import 'package:socratic_ai/core/route_observer.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/core/models/dashboard_models.dart';
import 'package:socratic_ai/features/chat/chat_page.dart';
import 'package:socratic_ai/features/dashboard/providers/dashboard_provider.dart';
import 'package:socratic_ai/features/dashboard/widgets/dashboard_header.dart';
import 'package:socratic_ai/features/dashboard/widgets/goal_card.dart';
import 'package:socratic_ai/features/dashboard/widgets/cross_pattern_card.dart';
import 'package:socratic_ai/features/dashboard/widgets/strategy_timeline.dart';
import 'package:socratic_ai/features/dashboard/goal_detail_page.dart';
import 'package:socratic_ai/features/history/history_page.dart';
import 'package:socratic_ai/features/model_manager/model_manage_page.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> with RouteAware {
  final DashboardProvider _provider = DashboardProvider();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _provider.addListener(_onStateChanged);
    _provider.load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _provider.removeListener(_onStateChanged);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didPopNext() {
    _provider.load();
  }

  void _onStateChanged(DashboardState state) {
    if (mounted) setState(() {});
  }

  void _startNewConversation() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const ChatPage(topic: ''),
      ),
    );
  }

  void _openHistory() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const HistoryPage()),
    );
  }

  void _openModelManager() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ModelManagePage()),
    );
  }

  void _showGoalStatusDialog(Goal goal) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改目标状态'),
        content: Text('将「${goal.title}」标记为？'),
        actions: [
          if (goal.status == GoalStatus.active) ...[
            TextButton(
              onPressed: () {
                _provider.toggleGoalStatus(goal.id!, GoalStatus.paused);
                Navigator.pop(ctx);
              },
              child: const Text('暂停'),
            ),
            TextButton(
              onPressed: () {
                _provider.toggleGoalStatus(goal.id!, GoalStatus.completed);
                Navigator.pop(ctx);
              },
              child: const Text('完成'),
            ),
          ],
          if (goal.status == GoalStatus.paused)
            TextButton(
              onPressed: () {
                _provider.toggleGoalStatus(goal.id!, GoalStatus.active);
                Navigator.pop(ctx);
              },
              child: const Text('恢复'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = _provider.state;

    return Scaffold(
      appBar: AppBar(
        title: const Text('首页'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _openModelManager,
            tooltip: '模型管理',
          ),
          IconButton(
            icon: const Icon(Icons.history),
            onPressed: _openHistory,
            tooltip: '历史记录',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _startNewConversation,
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
        elevation: 2,
        icon: const Icon(Icons.add_rounded, size: 20),
        label: const Text('新对话', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      ),
      body: state.isLoading
          ? const Center(child: CircularProgressIndicator())
          : state.error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error_outline,
                          size: 48, color: AppTheme.textSecondary),
                      const SizedBox(height: 16),
                      Text(state.error!,
                          style:
                              const TextStyle(color: AppTheme.textSecondary)),
                    ],
                  ),
                )
              : _buildDashboard(state),
    );
  }

  Widget _buildDashboard(DashboardState state) {
    final strategiesByGoal = <int, List<Strategy>>{};
    for (final s in state.strategies) {
      strategiesByGoal.putIfAbsent(s.goalId, () => []).add(s);
    }

    final activeGoals =
        state.goals.where((g) => g.status == GoalStatus.active).toList();

    // Build goal lookup map for timeline
    final goalMap = <int, Goal>{};
    for (final g in state.goals) {
      goalMap[g.id!] = g;
    }

    final pendingStrategyCount =
        state.strategies.where((s) => !s.completed).length;

    return ListView(
      key: const PageStorageKey('dashboard'),
      controller: _scrollController,
      primary: false,
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: DashboardHeader(
            activeGoalCount: state.activeGoalCount,
            pendingStrategyCount: state.pendingStrategyCount,
            patternCount: state.patternCount,
          ),
        ),
        const SizedBox(height: 28),

        // Zone 1: 目标与策略
        _buildSectionHeader('目标与策略', Icons.flag_rounded,
            count: activeGoals.length),
        const SizedBox(height: 10),
        if (activeGoals.isNotEmpty)
          ...activeGoals.map((goal) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: GoalCard(
                  goal: goal,
                  strategies: strategiesByGoal[goal.id] ?? [],
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => GoalDetailPage(
                          goal: goal,
                          strategies: strategiesByGoal[goal.id] ?? [],
                          onStrategyToggle: (s) => _provider
                              .toggleStrategy(s.id!, !s.completed),
                        ),
                      ),
                    );
                  },
                  onStatusTap: () => _showGoalStatusDialog(goal),
                ),
              ))
        else
          _buildEmptySection('暂无目标', '每次对话结束后，军师会帮你提炼目标'),

        // Zone 2: 执行路线 — global timeline of pending strategies
        const SizedBox(height: 28),
        _buildSectionHeader('执行路线', Icons.timeline_rounded,
            count: pendingStrategyCount, chipColor: AppTheme.secondary),
        const SizedBox(height: 10),
        if (pendingStrategyCount > 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: StrategyTimeline(
              strategies: state.strategies,
              goalMap: goalMap,
            ),
          )
        else
          _buildEmptySection(
              '暂无待办策略', '为目标设定策略后，这里会按优先级展示执行路线'),

        // Zone 3: 洞察
        const SizedBox(height: 28),
        _buildSectionHeader('洞察', Icons.lightbulb_rounded,
            count: state.crossPatterns.length, chipColor: AppTheme.accent),
        const SizedBox(height: 10),
        if (state.crossPatterns.isNotEmpty)
          ...state.crossPatterns.map((p) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: CrossPatternCard(pattern: p),
              ))
        else
          _buildEmptySection('暂无洞察', '多聊几次后，军师会帮你发现跨对话的自我认知'),
        const SizedBox(height: 80),
      ],
    );
  }

  Widget _buildSectionHeader(String title, IconData icon,
      {int count = 0, Color chipColor = AppTheme.primary}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Icon(icon, size: 18, color: chipColor),
          const SizedBox(width: 6),
          Text(title,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: chipColor.withAlpha(20),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('$count',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: chipColor)),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptySection(String title, String hint) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF8F8F4),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFEEEDE8), width: 1),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppTheme.textSecondary.withAlpha(15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.inbox_outlined,
                  size: 18, color: AppTheme.textSecondary.withAlpha(120)),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500, color: AppTheme.textSecondary)),
                const SizedBox(height: 2),
                Text(hint,
                    style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.textSecondary.withAlpha(160))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
