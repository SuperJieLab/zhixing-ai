import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:zhixing_ai/core/data/models/conversation.dart';
import 'package:zhixing_ai/core/data/models/dashboard_models.dart';
import 'package:zhixing_ai/core/llm/llm.dart';
import 'package:zhixing_ai/core/ui/theme.dart';
import 'package:zhixing_ai/features/strategy_brief/providers/strategy_brief_provider.dart';
import 'package:zhixing_ai/features/strategy_brief/strategy_detail_page.dart';

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
    _provider = StrategyBriefProvider(
      widget.conversation,
      llm: context.read<Llm>(),
    );
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
        title: const Text('分析结果'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
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
              Text('助手正在分析本次对话...',
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
                const Text('本次对话未发现新的建议',
                    style: TextStyle(fontSize: 16, color: AppTheme.textPrimary)),
                const SizedBox(height: 8),
                const Text(
                  '这次聊的内容比较轻松，助手没有提取到新的目标或策略。',
                  style: TextStyle(color: AppTheme.textSecondary),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                OutlinedButton(
                  onPressed: _returnToDashboard,
                  child: const Text('返回首页'),
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
                child: const Text('返回首页'),
              ),
            ],
          ),
        );
    }
  }

  Widget _buildContent(StrategyBriefState state) {
    final extraction = state.extraction!;
    final totalItems = extraction.newGoals.length +
        extraction.goalUpdates.length +
        extraction.crossPatterns.length;

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('助手从本次对话中发现了 $totalItems 条建议',
              style: const TextStyle(
                  fontSize: 14,
                  color: AppTheme.textSecondary,
                  fontWeight: FontWeight.w500)),
        ),
        const SizedBox(height: 20),

        // Zone 1: 新目标
        if (extraction.newGoals.isNotEmpty) ...[
          _buildSectionHeader('🎯 新目标', Icons.flag_rounded,
              count: extraction.newGoals.length),
          const SizedBox(height: 8),
          ...extraction.newGoals.asMap().entries.map((entry) {
            final goal = entry.value;
            final strategiesForGoal = extraction.strategies
                .where((s) => s.goalId == entry.key)
                .toList();

            return Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(goal.title,
                                style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600)),
                          ),
                          const Icon(Icons.chevron_right,
                              size: 18, color: AppTheme.textSecondary),
                        ],
                      ),
                      if (goal.notes != null && goal.notes!.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(goal.notes!,
                            style: const TextStyle(
                                fontSize: 13,
                                color: AppTheme.textSecondary)),
                      ],
                      if (strategiesForGoal.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        ...strategiesForGoal.map((s) => Padding(
                              padding:
                                  const EdgeInsets.only(bottom: 2),
                              child: Row(
                                children: [
                                  const Icon(Icons.task_alt,
                                      size: 14,
                                      color: AppTheme.primary),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(s.description,
                                        style: const TextStyle(
                                            fontSize: 13)),
                                  ),
                                ],
                              ),
                            )),
                      ],
                      const SizedBox(height: 12),
                      if (state.confirmedNewGoals.contains(entry.key))
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: AppTheme.primary.withAlpha(15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text('已添加',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: AppTheme.primary)),
                            ),
                          ],
                        )
                      else if (state.ignoredNewGoals.contains(entry.key))
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: AppTheme.textSecondary.withAlpha(15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text('已忽略',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: AppTheme.textSecondary)),
                            ),
                          ],
                        )
                      else
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () =>
                                  _provider.ignoreNewGoal(entry.key),
                              child: const Text('忽略',
                                  style: TextStyle(
                                      color: AppTheme.textSecondary)),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: () =>
                                  _provider.confirmNewGoal(entry.key),
                              child: const Text('确认'),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            );
          }),
          const SizedBox(height: 16),
        ],

        // Zone 2: 已有目标变更
        if (extraction.goalUpdates.isNotEmpty) ...[
          _buildSectionHeader('🔄 已有目标变更', Icons.update_rounded,
              count: extraction.goalUpdates.length,
              chipColor: AppTheme.secondary),
          const SizedBox(height: 8),
          ...extraction.goalUpdates.asMap().entries.map((entry) {
            final update = entry.value;
            final relatedGoal = state.existingGoals.firstWhere(
              (g) => g.title == update.goalTitle,
              orElse: () => Goal(
                  title: '',
                  createdAt: DateTime.now(),
                  updatedAt: DateTime.now()),
            );
            final relatedStrategies = state.existingGoals.isNotEmpty
                ? <Strategy>[]
                : <Strategy>[];

            return Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Card(
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: relatedGoal.title.isNotEmpty
                      ? () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => StrategyDetailPage(
                                goal: relatedGoal,
                                strategies: relatedStrategies,
                              ),
                            ),
                          )
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(update.goalTitle,
                                  style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600)),
                            ),
                            if (relatedGoal.title.isNotEmpty)
                              const Icon(Icons.chevron_right,
                                  size: 18,
                                  color: AppTheme.textSecondary),
                          ],
                        ),
                        const SizedBox(height: 4),
                        if (update.newStatus != null)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppTheme.accent.withAlpha(25),
                              borderRadius:
                                  BorderRadius.circular(4),
                            ),
                            child: Text(
                                '建议 → ${update.newStatus!.name}',
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.accent)),
                          ),
                        if (update.reason.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(update.reason,
                              style: const TextStyle(
                                  fontSize: 13,
                                  color: AppTheme.textSecondary)),
                        ],
                        const SizedBox(height: 12),
                        if (state.confirmedGoalUpdates.contains(entry.key))
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: AppTheme.primary.withAlpha(15),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Text('已应用',
                                    style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                        color: AppTheme.primary)),
                              ),
                            ],
                          )
                        else if (state.ignoredGoalUpdates.contains(entry.key))
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: AppTheme.textSecondary.withAlpha(15),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Text('已忽略',
                                    style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                        color: AppTheme.textSecondary)),
                              ),
                            ],
                          )
                        else
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () =>
                                    _provider.ignoreGoalUpdate(entry.key),
                                child: const Text('忽略',
                                    style: TextStyle(
                                        color: AppTheme.textSecondary)),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                onPressed: () =>
                                    _provider.confirmGoalUpdate(entry.key),
                                child: const Text('确认'),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
          const SizedBox(height: 16),
        ],

        // Zone 3: 洞察
        if (extraction.crossPatterns.isNotEmpty) ...[
          _buildSectionHeader('💡 洞察', Icons.lightbulb_rounded,
              count: extraction.crossPatterns.length,
              chipColor: AppTheme.accent),
          const SizedBox(height: 8),
          ...extraction.crossPatterns.asMap().entries.map((entry) {
            final pattern = entry.value;
            return Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFFAF6EF),
                  borderRadius: BorderRadius.circular(12),
                  border:
                      Border.all(color: const Color(0xFFE6DDCE), width: 1),
                ),
                padding: const EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: AppTheme.accent.withAlpha(30),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.lightbulb_rounded,
                          size: 18, color: AppTheme.accent),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(pattern.label,
                              style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 4),
                          Text(pattern.description,
                              style: const TextStyle(
                                  fontSize: 13,
                                  color: AppTheme.textSecondary)),
                        ],
                      ),
                    ),
                    if (state.deletedInsights.contains(entry.key))
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppTheme.textSecondary.withAlpha(15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text('已删除',
                            style: TextStyle(
                                fontSize: 10,
                                color: AppTheme.textSecondary)),
                      )
                    else
                      IconButton(
                        icon: const Icon(Icons.close,
                            size: 18, color: AppTheme.textSecondary),
                        onPressed: () =>
                            _provider.deleteInsight(entry.key),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 16),
        ],

        const SizedBox(height: 8),
        Center(
          child: OutlinedButton.icon(
            onPressed: _returnToDashboard,
            icon: const Icon(Icons.dashboard),
            label: const Text('返回首页'),
          ),
        ),
        const SizedBox(height: 32),
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
              style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: chipColor.withAlpha(20),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('$count',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: chipColor)),
          ),
        ],
      ),
    );
  }
}
