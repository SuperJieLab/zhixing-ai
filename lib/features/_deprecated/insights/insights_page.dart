import 'package:flutter/material.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/models/conversation.dart';
import 'package:socratic_ai/core/snackbar_throttle.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/_deprecated/insights/providers/insight_provider.dart';
import 'package:socratic_ai/features/_deprecated/insights/widgets/contradiction_card.dart';
import 'package:socratic_ai/features/_deprecated/insights/widgets/insight_card.dart';
import 'package:socratic_ai/features/_deprecated/insights/widgets/staggered_item.dart';
import 'package:socratic_ai/features/_deprecated/insights/widgets/value_tags.dart';
import 'package:socratic_ai/features/_deprecated/mindmap/mindmap_page.dart';
import 'package:socratic_ai/features/_deprecated/topics/topic_selection_page.dart';

/// 洞察总结页面
///
/// 展示 LLM 从完整对话中提取的结构化洞察。
/// 只依赖 [conversation]，内部通过 InsightProvider 按需获取/生成洞察。
class InsightsPage extends StatefulWidget {
  final Conversation conversation;

  /// 是否从历史列表进入（影响返回行为和 AppBar 样式）
  final bool fromHistory;

  const InsightsPage({
    super.key,
    required this.conversation,
    this.fromHistory = false,
  });

  @override
  State<InsightsPage> createState() => _InsightsPageState();
}

class _InsightsPageState extends State<InsightsPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  late final Animation<double> _fadeAnimation;

  /// 洞察页面状态（封装 InsightService）
  final InsightProvider _insightProvider = InsightProvider();

  /// provider 生成（或从 DB 加载）的洞察结果
  InsightResult? _insight;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOut,
    );

    // 通过 provider 加载/生成洞察（先查 conversation.insight → DB → LLM）
    _insightProvider.addListener(_onInsightReady);
    _insightProvider.generateInsights(conversation: widget.conversation);
  }

  void _onInsightReady() {
    if (_insightProvider.insight != null && mounted) {
      _insight = _insightProvider.insight;
      _insightProvider.removeListener(_onInsightReady);
      _animController.forward();
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _insightProvider.removeListener(_onInsightReady);
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 正在生成洞察 → 加载页
    if (_insight == null) {
      return Scaffold(
        backgroundColor: AppTheme.background,
        body: _buildLoadingState(),
      );
    }

    final insight = _insight!;
    final isEmpty =
        insight.coreInsights.isEmpty && insight.contradictionsFound.isEmpty;

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: widget.fromHistory
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.pop(context),
              )
            : const SizedBox.shrink(),
        actions: [
          if (!widget.fromHistory)
            TextButton(
              onPressed: () => _backToHome(context),
              child: const Text(
                '完成',
                style: TextStyle(color: AppTheme.primary),
              ),
            ),
        ],
      ),
      body: FadeTransition(
        opacity: _fadeAnimation,
        child: isEmpty ? _buildEmptyState() : _buildContent(insight),
      ),
    );
  }

  // ================================================================
  // 正常内容布局
  // ================================================================

  Widget _buildContent(InsightResult insight) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        _buildHeroHeader(),
        const SizedBox(height: 8),
        if (insight.coreInsights.isNotEmpty) ...[
          _buildSectionTitle('核心洞察'),
          const SizedBox(height: 12),
          ...insight.coreInsights.asMap().entries.map(
                (e) => StaggeredItem(
                  index: e.key,
                  child: InsightCard(index: e.key + 1, text: e.value),
                ),
              ),
        ],
        if (insight.underlyingValues.isNotEmpty) ...[
          const SizedBox(height: 28),
          _buildSectionTitle('底层价值观'),
          const SizedBox(height: 12),
          StaggeredItem(
            index: insight.coreInsights.length,
            child: ValueTags(values: insight.underlyingValues),
          ),
        ],
        if (insight.contradictionsFound.isNotEmpty) ...[
          const SizedBox(height: 28),
          _buildSectionTitle('认知矛盾'),
          const SizedBox(height: 12),
          ...insight.contradictionsFound.asMap().entries.map(
                (e) => StaggeredItem(
                  index: insight.coreInsights.length + 1 + e.key,
                  child: ContradictionCard(text: e.value),
                ),
              ),
        ],
        const SizedBox(height: 32),
        _buildActionButtons(),
      ],
    );
  }

  // ================================================================
  // 加载中状态（fresh 模式，等待 LLM 生成洞察）
  // ================================================================

  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(color: AppTheme.primary),
          const SizedBox(height: 20),
          Text(
            '正在生成洞察总结...',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: AppTheme.textSecondary,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            '「${widget.conversation.topic}」',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppTheme.textSecondary,
                ),
          ),
        ],
      ),
    );
  }

  // ================================================================
  // 空状态（LLM 未就绪时的回退）
  // ================================================================

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('🔍',
                style: Theme.of(context)
                    .textTheme
                    .displayMedium
                    ?.copyWith(fontSize: 48)),
            const SizedBox(height: 16),
            Text(
              '对话已结束',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              'AI 模型未加载，无法生成洞察总结。\n你可以稍后回来查看。',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary, height: 1.5),
            ),
            const SizedBox(height: 24),
            _buildActionButtons(),
          ],
        ),
      ),
    );
  }

  // ================================================================
  // 组件
  // ================================================================

  Widget _buildHeroHeader() {
    return Column(
      children: [
        const SizedBox(height: 16),
        Text('✨',
            style: Theme.of(context)
                .textTheme
                .displaySmall
                ?.copyWith(fontSize: 36)),
        const SizedBox(height: 12),
        Text(
          '「${widget.conversation.topic}」的对话洞察',
          style: Theme.of(context).textTheme.headlineMedium,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildSectionTitle(String title) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 16,
          decoration: const BoxDecoration(
            color: AppTheme.primary,
            borderRadius: BorderRadius.vertical(top: Radius.circular(2)),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary,
          ),
        ),
      ],
    );
  }

  Widget _buildActionButtons() {
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () => _backToHome(context),
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.primary,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('开始新对话', style: TextStyle(fontSize: 16)),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: widget.conversation.messages.isNotEmpty
                ? () => _openMindMap(context)
                : null,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text(
              '查看思维图谱',
              style: TextStyle(
                fontSize: 16,
                color: AppTheme.textSecondary,
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _backToHome(BuildContext context) {
    if (widget.fromHistory) {
      // 从历史列表进入 → 返回历史列表
      Navigator.pop(context);
    } else {
      // 从对话流程进入 → 清空栈回到首页
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const TopicSelectionPage()),
        (route) => false,
      );
    }
  }

  void _openMindMap(BuildContext context) {
    final messages = widget.conversation.messages;
    if (messages.isEmpty) {
      SnackBarThrottle.show(context, '暂无对话数据');
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MindMapPage(
          conversation: widget.conversation,
        ),
      ),
    );
  }
}
