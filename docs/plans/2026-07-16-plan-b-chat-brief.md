# Plan B: 对话重塑（Phase 4-7）

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 新增 StrategistPrompter（军师对话 prompt），ChatProvider 切换引擎，新增 StrategyBriefPage + Provider，更新 ChatPage 结束流程

**Architecture:** 新建 `StrategistPrompter` 实现 `DialogueEngine` 接口（保留 SocraticPrompter 不动），ChatProvider 注入新引擎，ChatPage 结束后走 `StrategyBriefPage`（非旧 InsightsPage），StrategyBriefProvider 管理提取展示和"返回大局观"导航

**Tech Stack:** Flutter 3.x + Provider + llama_cpp_dart

**依赖:** Plan A 完成后再执行

---

### Task 1: StrategistPrompter — 军师对话 Prompt

**Files:**
- Create: `lib/features/chat/engine/strategist_prompter.dart`
- Reference: `lib/features/chat/engine/socratic_prompter.dart`（保留不动）

**Step 1: 创建文件**

```dart
import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;
import 'package:socratic_ai/core/engine/dialogue_engine.dart';
import 'package:socratic_ai/core/engine/llama_service.dart';
import 'package:socratic_ai/core/logger.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/think_tag_stripper.dart';

class StrategistPrompter implements DialogueEngine {
  final LlamaService _llamaService;

  EngineChat? _chat;
  bool _initialized = false;

  // 去重相关
  final List<String> _recentQuestions = [];
  int _roundIndex = 0;
  int _estimatedTokens = 0;
  static const int _contextWarnThreshold = 3500;

  StrategistPrompter(this._llamaService);

  static const _strategistSystemPrompt = '''
你是一位经验丰富的军师。主公来找你商量事情时，你的职责是：

1. 先理解主公的真实处境和核心诉求
2. 帮主公把模糊的问题拆解成清晰的子问题
3. 给出具体的分析和可执行的策略建议
4. 区分"主公自己能做的"（selfAction）和"需要外部条件配合的"（externalDep）
5. 在适当时候追问，帮助主公想得更深

风格要求：
- 像朋友一样真诚，不端着
- 给具体建议，不说空话
- 分析为什么这样建议，让主公理解背后的逻辑
- 每次回复控制在 3-5 句话内，简洁有力
- 不要使用 <think> 标签
''';

  @override
  bool get isReady => _llamaService.isEngineReady;

  @override
  Future<bool> initialize() async {
    if (_initialized) return true;
    final ok = await _llamaService.ensureReady();
    if (!ok) return false;

    _chat = _llamaService.engine!.createChat(
      contextSize: 4096,
      maxTokens: 2048,
    );
    _chat!.addSystem(_strategistSystemPrompt);
    _estimatedTokens = LlamaService.estimateTokens(_strategistSystemPrompt);

    _initialized = true;
    return true;
  }

  @override
  void seedHistory(List<ChatMessage> messages) {
    if (_chat == null) return;
    for (final msg in messages) {
      if (msg.role == MessageRole.ai) {
        _chat!.addAssistant(msg.content);
        _estimatedTokens += LlamaService.estimateTokens(msg.content);
      }
    }
  }

  @override
  Stream<String> generateResponse(String userMessage) async* {
    if (_chat == null) {
      AppLogger.warn('StrategistPrompter', '引擎未初始化');
      yield '军师尚在准备中，请稍后再来。';
      return;
    }

    // 去重检测
    if (_isDuplicate(userMessage)) {
      AppLogger.info('StrategistPrompter', '检测到重复输入，换角度重新回答');
      _chat!.addUser('$userMessage（请从不同的角度回答，不要重复之前的观点）');
    } else {
      _chat!.addUser(userMessage);
    }

    _estimatedTokens += LlamaService.estimateTokens(userMessage);
    _roundIndex++;

    if (_estimatedTokens > _contextWarnThreshold) {
      AppLogger.warn('StrategistPrompter',
          '上下文接近上限: ~$_estimatedTokens / 4096 tokens');
    }

    final buffer = StringBuffer();
    try {
      await for (final token in _chat!.generate()) {
        buffer.write(token);
        yield token;
      }
      final fullReply = stripThinkTags(buffer.toString());
      _chat!.addAssistant(fullReply);
      _estimatedTokens += LlamaService.estimateTokens(fullReply);
    } catch (e) {
      AppLogger.error('StrategistPrompter', '生成回复失败', e);
      yield '\n\n[军师暂时无法回应，请稍后再试]';
    }
  }

  @override
  void dispose() {
    _chat?.dispose();
    _chat = null;
    _initialized = false;
  }

  // --- 去重 ---

  bool _isDuplicate(String input) {
    final trimmed = input.trim();
    if (_recentQuestions.isEmpty) {
      _recentQuestions.add(trimmed);
      return false;
    }

    // 完全相同 → 重复
    if (_recentQuestions.last == trimmed) return true;

    // LCS 检测 → 高度相似
    final lcs = _lcsSimilarity(_recentQuestions.last, trimmed);
    if (lcs > 0.8) return true;

    _recentQuestions.add(trimmed);
    if (_recentQuestions.length > 5) _recentQuestions.removeAt(0);
    return false;
  }

  double _lcsSimilarity(String a, String b) {
    final m = a.length;
    final n = b.length;
    final dp = List.generate(m + 1, (_) => List.filled(n + 1, 0));
    for (var i = 1; i <= m; i++) {
      for (var j = 1; j <= n; j++) {
        if (a[i - 1] == b[j - 1]) {
          dp[i][j] = dp[i - 1][j - 1] + 1;
        } else {
          dp[i][j] = dp[i - 1][j] > dp[i][j - 1] ? dp[i - 1][j] : dp[i][j - 1];
        }
      }
    }
    final lcs = dp[m][n];
    return lcs / (m > n ? m : n);
  }
}
```

**Step 2: 验证**

```bash
flutter analyze lib/features/chat/engine/strategist_prompter.dart
```

**Step 3: 提交**

```bash
git add lib/features/chat/engine/strategist_prompter.dart
git commit -m "feat: add StrategistPrompter with strategist conversation prompt"
```

---

### Task 2: ChatProvider 切换引擎

**Files:**
- Modify: `lib/features/chat/providers/chat_provider.dart`

**改动**：将 `SocraticPrompter` 替换为 `StrategistPrompter`

**Step 1: 修改 import**

```dart
// 删除
import '../engine/socratic_prompter.dart';
// 新增
import '../engine/strategist_prompter.dart';
```

**Step 2: 修改引擎构造**

```dart
// 旧的（约第 83 行）
_engine = SocraticPrompter(_llamaService);
// 改为
_engine = StrategistPrompter(_llamaService);
```

**Step 3: 修改欢迎语**

```dart
// 旧的苏格拉底风格欢迎语
// 改为军师风格
ChatMessage(
  role: MessageRole.ai,
  content: '主公请讲，军师在此。有任何困惑或打算，尽管说来——我帮你看清局势，给出策略。',
  round: 0,
)
```

**Step 4: 验证**

```bash
flutter analyze lib/features/chat/providers/chat_provider.dart
```

**Step 5: 提交**

```bash
git add lib/features/chat/providers/chat_provider.dart
git commit -m "refactor: switch ChatProvider from SocraticPrompter to StrategistPrompter"
```

---

### Task 3: StrategyBriefProvider（策略简报状态管理）

**Files:**
- Create: `lib/features/strategy_brief/providers/strategy_brief_provider.dart`

**Step 1: 创建文件**

```dart
import 'package:socratic_ai/core/logger.dart';
import 'package:socratic_ai/core/engine/strategist_extractor.dart';
import 'package:socratic_ai/core/models/conversation.dart';
import 'package:socratic_ai/core/models/dashboard_models.dart';
import 'package:socratic_ai/core/repository/dashboard_repository.dart';

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

  StrategyBriefState({
    this.status = BriefStatus.loading,
    this.extraction,
    this.existingGoals = const [],
    this.errorMessage,
  });
}

class StrategyBriefProvider {
  final Conversation _conversation;
  final StrategistExtractor _extractor = StrategistExtractor();
  final DashboardRepository _dashboardRepo = DashboardRepository();

  StrategyBriefState _state = StrategyBriefState();
  StrategyBriefState get state => _state;

  final List<void Function(StrategyBriefState)> _listeners = [];

  StrategyBriefProvider(this._conversation);

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

  /// 执行提取流程
  Future<void> extract() async {
    _state = StrategyBriefState(status: BriefStatus.extracting);
    _notify();

    try {
      final existingGoals = await _dashboardRepo.getAllGoals();
      _state = StrategyBriefState(
        status: BriefStatus.extracting,
        existingGoals: existingGoals,
      );
      _notify();

      final result = await _extractor.extract(
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
      }
    } catch (e) {
      AppLogger.error('StrategyBriefProvider', '提取失败', e);
      _state = StrategyBriefState(
        status: BriefStatus.error,
        errorMessage: e.toString(),
      );
    }
    _notify();
  }
}
```

**Step 2: 验证**

```bash
flutter analyze lib/features/strategy_brief/providers/strategy_brief_provider.dart
```

**Step 3: 提交**

```bash
git add lib/features/strategy_brief/providers/strategy_brief_provider.dart
git commit -m "feat: add StrategyBriefProvider for extraction state management"
```

---

### Task 4: StrategyBriefPage — 大局影响页面

**Files:**
- Create: `lib/features/strategy_brief/strategy_brief_page.dart`

**Step 1: 创建文件**

```dart
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
                    style: TextStyle(fontSize: 16, color: AppTheme.textPrimary)),
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
              const Icon(Icons.error_outline, size: 48, color: AppTheme.textSecondary),
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
                            style: const TextStyle(color: AppTheme.textSecondary)),
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
                            style: const TextStyle(color: AppTheme.primary)),
                      if (update.reason.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(update.reason,
                            style: const TextStyle(color: AppTheme.textSecondary)),
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
                  leading: const Icon(Icons.task_alt, color: AppTheme.primary),
                  title: Text(s.description),
                  subtitle: s.nextStep != null ? Text('下一步: ${s.nextStep}') : null,
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
                          style: const TextStyle(color: AppTheme.textSecondary)),
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
```

**Step 2: 验证**

```bash
flutter analyze lib/features/strategy_brief/strategy_brief_page.dart
```

**Step 3: 提交**

```bash
git add lib/features/strategy_brief/strategy_brief_page.dart
git commit -m "feat: add StrategyBriefPage with extraction result display"
```

---

### Task 5: ChatPage — 更新 `_endConversation` 流程

**Files:**
- Modify: `lib/features/chat/chat_page.dart`

**改动**：将 `_endConversation` 的目标页从 `InsightsPage` 改为 `StrategyBriefPage`

**Step 1: 修改 import**

```dart
// 删除
import 'package:socratic_ai/features/_deprecated/insights/insights_page.dart';
// 新增
import 'package:socratic_ai/features/strategy_brief/strategy_brief_page.dart';
```

**Step 2: 修改 `_endConversation`**

```dart
void _endConversation(BuildContext context) {
  final chatProvider = context.read<ChatProvider>();
  final activeId = chatProvider.activeConversationId;

  if (!context.mounted) return;

  final conversation = (widget.conversation != null)
      ? widget.conversation!
      : Conversation(
          id: activeId,
          topic: widget.topic,
          messages: chatProvider.messages,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

  // 注册到 ConversationService 缓存
  ConversationService().cacheConversation(conversation);

  if (!context.mounted) return;
  Navigator.pushReplacement(
    context,
    MaterialPageRoute(
      builder: (_) => StrategyBriefPage(conversation: conversation),
    ),
  );
}
```

**Step 3: 检查是否有遗留的 InsightsPage 引用**

```bash
grep -rn "InsightsPage" lib/features/chat/chat_page.dart
```

应该只在 import 出现（已改为 _deprecated 路径），且没有实例化使用。如果有残留，清理掉。

**Step 4: 验证**

```bash
flutter analyze lib/features/chat/chat_page.dart
```

**Step 5: 提交**

```bash
git add lib/features/chat/chat_page.dart
git commit -m "refactor: ChatPage._endConversation → StrategyBriefPage"
```

---

### Task 6: 最终验证

```bash
flutter analyze lib/
```

预期零 error 零 warning。

---

**Plan B 完成。** 产出：
- `lib/features/chat/engine/strategist_prompter.dart`
- `lib/features/strategy_brief/strategy_brief_page.dart`
- `lib/features/strategy_brief/providers/strategy_brief_provider.dart`
- ChatProvider 切换引擎 + ChatPage 流程更新
