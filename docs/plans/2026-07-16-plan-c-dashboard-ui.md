# Plan C: 面板 UI & 入口切换（Phase 8-10）

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 构建 DashboardPage UI（目标卡片 + 策略条目 + 跨对话发现 + 统计概览 + 新对话按钮），切换 main.dart 入口为 DashboardPage，清理旧路由

**Architecture:** DashboardPage 通过 `DashboardProvider` 获取全局面板数据，Goal 卡片暂时无交互。`main.dart` 和 `app.dart` 切换入口为 DashboardPage。旧 TopicSelectionPage 的路由保留在 `_deprecated` 中不删

**Tech Stack:** Flutter 3.x + Provider

**依赖:** Plan A + Plan B 完成后再执行

---

### Task 1: DashboardHeader — 统计概览组件

**Files:**
- Create: `lib/features/dashboard/widgets/dashboard_header.dart`

**Step 1: 创建文件**

```dart
import 'package:flutter/material.dart';
import 'package:socratic_ai/core/theme.dart';

class DashboardHeader extends StatelessWidget {
  final int activeGoalCount;
  final int pendingStrategyCount;
  final int patternCount;

  const DashboardHeader({
    super.key,
    required this.activeGoalCount,
    required this.pendingStrategyCount,
    required this.patternCount,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _StatItem(label: '活跃目标', value: '$activeGoalCount'),
          _StatItem(label: '待执行', value: '$pendingStrategyCount'),
          _StatItem(label: '发现', value: '$patternCount'),
        ],
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final String label;
  final String value;

  const _StatItem({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style: const TextStyle(
                fontSize: 28, fontWeight: FontWeight.bold, color: AppTheme.primary)),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
      ],
    );
  }
}
```

**Step 2: 验证**

```bash
flutter analyze lib/features/dashboard/widgets/dashboard_header.dart
```

**Step 3: 提交**

```bash
git add lib/features/dashboard/widgets/dashboard_header.dart
git commit -m "feat: add DashboardHeader stat overview widget"
```

---

### Task 2: GoalCard — 目标卡片组件

**Files:**
- Create: `lib/features/dashboard/widgets/goal_card.dart`

**Step 1: 创建文件**

```dart
import 'package:flutter/material.dart';
import 'package:socratic_ai/core/models/dashboard_models.dart';
import 'package:socratic_ai/core/theme.dart';

class GoalCard extends StatelessWidget {
  final Goal goal;
  final List<Strategy> strategies;
  final VoidCallback? onTap;

  const GoalCard({
    super.key,
    required this.goal,
    this.strategies = const [],
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final statusIcon = _statusIcon(goal.status);
    final categoryLabel = _categoryLabel(goal.category);

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(statusIcon.icon, size: 18, color: statusIcon.color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(goal.title,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w500)),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withAlpha(20),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(categoryLabel,
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.primary)),
                  ),
                ],
              ),
              if (goal.sourceConvIds.length > 1) ...[
                const SizedBox(height: 4),
                Text('来源: ${goal.sourceConvIds.length} 次对话',
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary)),
              ],
              if (strategies.isNotEmpty) ...[
                const SizedBox(height: 8),
                const Divider(height: 1),
                const SizedBox(height: 8),
                ...strategies.map((s) => _StrategyRow(strategy: s)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static ({IconData icon, Color color}) _statusIcon(GoalStatus status) {
    switch (status) {
      case GoalStatus.active:
        return (icon: Icons.circle, color: AppTheme.primary);
      case GoalStatus.completed:
        return (icon: Icons.check_circle, color: Colors.green);
      case GoalStatus.paused:
        return (icon: Icons.pause_circle, color: AppTheme.textSecondary);
    }
  }

  static String _categoryLabel(GoalCategory category) {
    switch (category) {
      case GoalCategory.career:
        return '职业';
      case GoalCategory.finance:
        return '财务';
      case GoalCategory.relationship:
        return '人际';
      case GoalCategory.health:
        return '健康';
      case GoalCategory.growth:
        return '成长';
      case GoalCategory.other:
        return '其他';
    }
  }
}

class _StrategyRow extends StatelessWidget {
  final Strategy strategy;

  const _StrategyRow({required this.strategy});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            strategy.completed ? Icons.check_box : Icons.check_box_outline_blank,
            size: 18,
            color: strategy.completed ? AppTheme.textSecondary : AppTheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(strategy.description,
                style: TextStyle(
                    fontSize: 13,
                    color: strategy.completed
                        ? AppTheme.textSecondary
                        : AppTheme.textPrimary)),
          ),
        ],
      ),
    );
  }
}
```

**Step 2: 验证**

```bash
flutter analyze lib/features/dashboard/widgets/goal_card.dart
```

**Step 3: 提交**

```bash
git add lib/features/dashboard/widgets/goal_card.dart
git commit -m "feat: add GoalCard widget with strategies"
```

---

### Task 3: CrossPatternCard — 跨对话发现卡片

**Files:**
- Create: `lib/features/dashboard/widgets/cross_pattern_card.dart`

**Step 1: 创建文件**

```dart
import 'package:flutter/material.dart';
import 'package:socratic_ai/core/models/dashboard_models.dart';
import 'package:socratic_ai/core/theme.dart';

class CrossPatternCard extends StatelessWidget {
  final CrossPattern pattern;

  const CrossPatternCard({super.key, required this.pattern});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppTheme.primary.withAlpha(15),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('💡', style: TextStyle(fontSize: 20)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(pattern.label,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(pattern.description,
                      style: const TextStyle(
                          fontSize: 13, color: AppTheme.textSecondary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

**Step 2: 验证**

```bash
flutter analyze lib/features/dashboard/widgets/cross_pattern_card.dart
```

**Step 3: 提交**

```bash
git add lib/features/dashboard/widgets/cross_pattern_card.dart
git commit -m "feat: add CrossPatternCard widget"
```

---

### Task 4: DashboardPage — 全局面板主页面

**Files:**
- Create: `lib/features/dashboard/dashboard_page.dart`

**Step 1: 创建文件**

```dart
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
    // 直接进入 ChatPage（无 topic 预设，用户自由输入）
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
                          style: const TextStyle(color: AppTheme.textSecondary)),
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
                  style: TextStyle(fontSize: 18, color: AppTheme.textPrimary)),
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

    // 按 goal 分组 strategies
    final strategiesByGoal = <int, List<Strategy>>{};
    for (final s in state.strategies) {
      strategiesByGoal.putIfAbsent(s.goalId, () => []).add(s);
    }

    final activeGoals = state.goals.where((g) => g.status == GoalStatus.active).toList();

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
          const Text('🎯 活跃目标',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...activeGoals.map((goal) => GoalCard(
                goal: goal,
                strategies: strategiesByGoal[goal.id] ?? [],
                onTap: null, // 暂不交互
              )),
          const SizedBox(height: 16),
        ],
        if (state.crossPatterns.isNotEmpty) ...[
          const Text('🔍 跨对话发现',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...state.crossPatterns
              .map((p) => CrossPatternCard(pattern: p)),
          const SizedBox(height: 16),
        ],
        const SizedBox(height: 80), // 给 FAB 留空间
      ],
    );
  }
}
```

**Step 2: 验证**

```bash
flutter analyze lib/features/dashboard/dashboard_page.dart
```

**Step 3: 提交**

```bash
git add lib/features/dashboard/dashboard_page.dart
git commit -m "feat: add DashboardPage with goals/strategies/patterns display"
```

---

### Task 5: 入口切换 — main.dart + app.dart

**Files:**
- Modify: `lib/app.dart`
- Modify: `lib/main.dart`

**Step 1: 修改 `lib/app.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/dashboard/dashboard_page.dart';

class SocraticApp extends StatelessWidget {
  const SocraticApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Socratic AI',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      home: const DashboardPage(),  // 改为 DashboardPage
    );
  }
}
```

**Step 2: 修改 `lib/main.dart`** — 只需更新注释

```dart
// 旧的注释
/// 2. 注入全局 Provider（ModelManager）
// 改为
/// 2. 注入全局 Provider（ModelManager）
/// 3. 启动 App（主页为 DashboardPage）
```

**Step 3: 清理 `ChatPage` 构造参数**

由于 Dashboard 的 `_startNewConversation` 传入 `topic: ''`（空字符串），ChatPage 需要处理空 topic 的情况：

检查 `ChatPage` 中 `widget.topic` 的使用：
- 欢迎语：如果 topic 为空，使用通用欢迎语
- 话题标签/标题：显示 "自由对话" 或其他兜底文本

在 `chat_provider.dart` 中：

```dart
String _buildWelcome(String topic) {
  if (topic.isEmpty) {
    return '主公请讲，军师在此。有任何困惑或打算，尽管说来。';
  }
  return '主公提到想聊聊$topic——请详细说说你的想法，我来帮你分析。';
}
```

**Step 4: 验证**

```bash
flutter analyze lib/
```

**Step 5: 提交**

```bash
git add lib/app.dart lib/main.dart
git commit -m "refactor: switch app entry to DashboardPage"
```

---

### Task 6: 最终验证

```bash
flutter analyze lib/
flutter test
```

预期零 error 零 warning。

冒烟测试清单：
1. App 启动 → 看到 DashboardPage（空状态，提示"开始新对话"）
2. 点击 FAB → 进入 ChatPage（军师欢迎语）
3. 对话几轮 → 点击结束按钮 → 进入 StrategyBriefPage（提取结果或轻量总结）
4. 点击"返回大局观" → 回到 DashboardPage（如果有新 goal 应该显示）

---

**Plan C 完成。** 产出：
- `lib/features/dashboard/dashboard_page.dart`
- `lib/features/dashboard/widgets/dashboard_header.dart`
- `lib/features/dashboard/widgets/goal_card.dart`
- `lib/features/dashboard/widgets/cross_pattern_card.dart`
- `lib/app.dart` — 入口切换
