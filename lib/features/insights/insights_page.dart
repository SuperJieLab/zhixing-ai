import 'package:flutter/material.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/insights/widgets/contradiction_card.dart';
import 'package:socratic_ai/features/insights/widgets/insight_card.dart';
import 'package:socratic_ai/features/insights/widgets/staggered_item.dart';
import 'package:socratic_ai/features/insights/widgets/value_tags.dart';
import 'package:socratic_ai/features/mindmap/mindmap_page.dart';
import 'package:socratic_ai/features/mindmap/engine/mindmap_service.dart';
import 'package:socratic_ai/features/topics/topic_selection_page.dart';

/// 洞察总结页面
///
/// 用户点击「结束对话」后跳转到此页面。
/// 展示 LLM 从完整对话中提取的结构化洞察：
/// - 核心洞察卡片（带编号）
/// - 价值观标签云
/// - 认知矛盾高亮卡片
/// - Stagger 入场动画
/// - 「开始新对话」和「查看思维图谱」按钮
class InsightsPage extends StatefulWidget {
  final InsightResult insight;
  final String topic;

  /// 对话思维图谱（预生成好的，如从历史读取；可为 null）
  final ConversationGraph? graph;

  /// 对话消息列表（用于按需生成图谱；为 null 时按钮不可用）
  final List<ChatMessage>? messages;

  /// 是否从历史列表进入（影响返回行为和 AppBar 样式）
  final bool fromHistory;

  const InsightsPage({
    super.key,
    required this.insight,
    required this.topic,
    this.graph,
    this.messages,
    this.fromHistory = false,
  });

  @override
  State<InsightsPage> createState() => _InsightsPageState();
}

class _InsightsPageState extends State<InsightsPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  late final Animation<double> _fadeAnimation;

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
    _animController.forward();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final insight = widget.insight;
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
          '「${widget.topic}」的对话洞察',
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
            onPressed: widget.messages != null
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
    // 已有预生成的图谱 → 直接打开
    if (widget.graph != null && widget.graph!.isNotEmpty) {
      _navigateToMindMap(widget.graph!);
      return;
    }

    final messages = widget.messages;
    if (messages == null || messages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂无对话数据')),
      );
      return;
    }

    MindMapService().openMindMap(context, widget.topic, messages);
  }

  void _navigateToMindMap(ConversationGraph graph) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MindMapPage(graph: graph, topic: widget.topic),
      ),
    );
  }
}
