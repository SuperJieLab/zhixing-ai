import 'package:flutter/material.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/core/models/dashboard_models.dart';
import 'package:socratic_ai/features/chat/chat_page.dart';
import 'package:socratic_ai/features/dashboard/providers/dashboard_provider.dart';
import 'package:socratic_ai/features/dashboard/widgets/dashboard_header.dart';
import 'package:socratic_ai/features/dashboard/widgets/goal_card.dart';
import 'package:socratic_ai/features/dashboard/widgets/cross_pattern_card.dart';
import 'package:socratic_ai/features/history/history_page.dart';
import 'package:socratic_ai/features/model_manager/model_manage_page.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final DashboardProvider _provider = DashboardProvider();

  @override
  void initState() {
    super.initState();
    _provider.addListener(_onStateChanged);
    _provider.load();
  }

  @override
  void dispose() {
    _provider.removeListener(_onStateChanged);
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    final state = _provider.state;

    return Scaffold(
      appBar: AppBar(
        title: const Text('大局观'),
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
        icon: const Icon(Icons.add),
        label: const Text('新对话'),
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
    if (state.goals.isEmpty && state.crossPatterns.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.dashboard_customize,
                  size: 64, color: AppTheme.textSecondary),
              const SizedBox(height: 16),
              const Text('大局观尚为空',
                  style:
                      TextStyle(fontSize: 18, color: AppTheme.textPrimary)),
              const SizedBox(height: 8),
              const Text(
                '点击下方「新对话」开始你的第一次军师对话。\n每次对话结束后，军师会帮你梳理目标和策略。',
                style: TextStyle(color: AppTheme.textSecondary),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    final strategiesByGoal = <int, List<Strategy>>{};
    for (final s in state.strategies) {
      strategiesByGoal.putIfAbsent(s.goalId, () => []).add(s);
    }

    final activeGoals =
        state.goals.where((g) => g.status == GoalStatus.active).toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        DashboardHeader(
          activeGoalCount: state.activeGoalCount,
          pendingStrategyCount: state.pendingStrategyCount,
          patternCount: state.patternCount,
        ),
        const SizedBox(height: 8),
        if (activeGoals.isNotEmpty) ...[
          const Text('活跃目标',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...activeGoals.map((goal) => GoalCard(
                goal: goal,
                strategies: strategiesByGoal[goal.id] ?? [],
                onTap: null,
              )),
          const SizedBox(height: 16),
        ],
        if (state.crossPatterns.isNotEmpty) ...[
          const Text('跨对话发现',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...state.crossPatterns.map((p) => CrossPatternCard(pattern: p)),
          const SizedBox(height: 16),
        ],
        const SizedBox(height: 80),
      ],
    );
  }
}
