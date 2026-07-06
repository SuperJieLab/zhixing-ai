import 'package:flutter/material.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/theme.dart';
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
  /// 已解析的对话洞察结果
  final InsightResult insight;

  /// 对话话题
  final String topic;

  const InsightsPage({
    super.key,
    required this.insight,
    required this.topic,
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
        leading: const SizedBox.shrink(),
        actions: [
          TextButton(
            onPressed: () => _backToHome(context),
            child:
                const Text('完成', style: TextStyle(color: AppTheme.primary)),
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
                (e) => _StaggeredItem(
                  index: e.key,
                  child: _InsightCard(index: e.key + 1, text: e.value),
                ),
              ),
        ],
        if (insight.underlyingValues.isNotEmpty) ...[
          const SizedBox(height: 28),
          _buildSectionTitle('底层价值观'),
          const SizedBox(height: 12),
          _StaggeredItem(
            index: insight.coreInsights.length,
            child: _ValueTags(values: insight.underlyingValues),
          ),
        ],
        if (insight.contradictionsFound.isNotEmpty) ...[
          const SizedBox(height: 28),
          _buildSectionTitle('认知矛盾'),
          const SizedBox(height: 12),
          ...insight.contradictionsFound.asMap().entries.map(
                (e) => _StaggeredItem(
                  index: insight.coreInsights.length + 1 + e.key,
                  child: _ContradictionCard(text: e.value),
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
            onPressed: null, // Day 7 启用
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
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const TopicSelectionPage()),
      (route) => false,
    );
  }
}

// ================================================================
// 核心洞察卡片
// ================================================================

class _InsightCard extends StatelessWidget {
  final int index;
  final String text;

  const _InsightCard({required this.index, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE8E4DF)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 26,
              height: 26,
              decoration: const BoxDecoration(
                color: AppTheme.primary,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                '$index',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                  fontSize: 15,
                  color: AppTheme.textPrimary,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ================================================================
// 价值观标签云
// ================================================================

class _ValueTags extends StatelessWidget {
  final List<String> values;

  const _ValueTags({required this.values});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: values.map((v) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFE0D9D1)),
          ),
          child: Text(
            v,
            style: const TextStyle(
              fontSize: 13,
              color: AppTheme.secondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        );
      }).toList(),
    );
  }
}

// ================================================================
// 认知矛盾卡片
// ================================================================

class _ContradictionCard extends StatelessWidget {
  final String text;

  const _ContradictionCard({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF8F0),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE8C89E)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text('⚡', style: TextStyle(fontSize: 16)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                  fontSize: 14,
                  color: AppTheme.textPrimary,
                  height: 1.5,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ================================================================
// Stagger 入场动画包装器
// ================================================================

class _StaggeredItem extends StatefulWidget {
  final int index;
  final Widget child;

  const _StaggeredItem({required this.index, required this.child});

  @override
  State<_StaggeredItem> createState() => _StaggeredItemState();
}

class _StaggeredItemState extends State<_StaggeredItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeAnim;
  late final Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    _fadeAnim = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.15),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    ));

    // Stagger delay：每个 item 延迟 120ms
    Future.delayed(Duration(milliseconds: 120 * widget.index), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnim,
      child: SlideTransition(
        position: _slideAnim,
        child: widget.child,
      ),
    );
  }
}
