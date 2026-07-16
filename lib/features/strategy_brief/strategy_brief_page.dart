import 'package:flutter/material.dart';
import 'package:socratic_ai/core/models/conversation.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/strategy_brief/providers/strategy_brief_provider.dart';

class StrategyBriefPage extends StatefulWidget {
  final Conversation conversation;

  const StrategyBriefPage({super.key, required this.conversation});

  @override
  State<StrategyBriefPage> createState() => _StrategyBriefPageState();
}

class _StrategyBriefPageState extends State<StrategyBriefPage> {
  late final StrategyBriefProvider _provider;

  @override
  void initState() {
    super.initState();
    _provider = StrategyBriefProvider(widget.conversation);
    _provider.addListener(_onStateChanged);
    _provider.extract();
  }

  @override
  void dispose() {
    _provider.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged(StrategyBriefState state) {
    if (mounted) setState(() {});
  }

  void _returnToDashboard() {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final state = _provider.state;

    return Scaffold(
      appBar: AppBar(
        title: const Text('大局影响'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _returnToDashboard,
        ),
      ),
      body: _buildBody(state),
    );
  }

  Widget _buildBody(StrategyBriefState state) {
    switch (state.status) {
      case BriefStatus.loading:
      case BriefStatus.extracting:
        return const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('军师正在分析本次对话...',
                  style: TextStyle(color: AppTheme.textSecondary)),
            ],
          ),
        );

      case BriefStatus.noContent:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.chat_bubble_outline,
                    size: 48, color: AppTheme.textSecondary),
                const SizedBox(height: 16),
                const Text('本次对话未发现新的目标或策略',
                    style:
                        TextStyle(fontSize: 16, color: AppTheme.textPrimary)),
                const SizedBox(height: 8),
                const Text(
                  '这次聊的内容比较轻松，军师没有提取到新的目标。下次聊得深入些，我会帮你梳理出更清晰的策略。',
                  style: TextStyle(color: AppTheme.textSecondary),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                OutlinedButton(
                  onPressed: _returnToDashboard,
                  child: const Text('返回大局观'),
                ),
              ],
            ),
          ),
        );

      case BriefStatus.hasContent:
        return _buildContent(state);

      case BriefStatus.error:
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline,
                  size: 48, color: AppTheme.textSecondary),
              const SizedBox(height: 16),
              Text(state.errorMessage ?? '分析失败',
                  style: const TextStyle(color: AppTheme.textSecondary)),
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: _returnToDashboard,
                child: const Text('返回大局观'),
              ),
            ],
          ),
        );
    }
  }

  Widget _buildContent(StrategyBriefState state) {
    final extraction = state.extraction!;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (extraction.newGoals.isNotEmpty) ...[
          const Text('🎯 新目标',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...extraction.newGoals.map((goal) => Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(goal.title,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w500)),
                      if (goal.notes != null) ...[
                        const SizedBox(height: 4),
                        Text(goal.notes!,
                            style: const TextStyle(
                                color: AppTheme.textSecondary)),
                      ],
                    ],
                  ),
                ),
              )),
          const SizedBox(height: 16),
        ],
        if (extraction.goalUpdates.isNotEmpty) ...[
          const Text('📋 已更新目标',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...extraction.goalUpdates.map((update) => Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(update.goalTitle,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w500)),
                      if (update.newStatus != null)
                        Text('状态 → ${update.newStatus!.name}',
                            style:
                                const TextStyle(color: AppTheme.primary)),
                      if (update.reason.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(update.reason,
                            style: const TextStyle(
                                color: AppTheme.textSecondary)),
                      ],
                    ],
                  ),
                ),
              )),
          const SizedBox(height: 16),
        ],
        if (extraction.strategies.isNotEmpty) ...[
          const Text('📝 建议策略',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...extraction.strategies.map((s) => Card(
                child: ListTile(
                  leading:
                      const Icon(Icons.task_alt, color: AppTheme.primary),
                  title: Text(s.description),
                  subtitle: s.nextStep != null
                      ? Text('下一步: ${s.nextStep}')
                      : null,
                ),
              )),
          const SizedBox(height: 16),
        ],
        if (extraction.crossPatterns.isNotEmpty) ...[
          const Text('🔍 跨对话发现',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...extraction.crossPatterns.map((p) => Card(
                color: AppTheme.primary.withAlpha(20),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.label,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text(p.description,
                          style: const TextStyle(
                              color: AppTheme.textSecondary)),
                    ],
                  ),
                ),
              )),
          const SizedBox(height: 16),
        ],
        const SizedBox(height: 8),
        Center(
          child: OutlinedButton.icon(
            onPressed: _returnToDashboard,
            icon: const Icon(Icons.dashboard),
            label: const Text('返回大局观'),
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }
}
