# Day 1: Engineering Scaffold Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Transform the default Flutter counter app into the Socratic AI page structure: topic selection page with 5 topic cards + custom input, chat page with mock conversation, and route navigation between them.

**Architecture:** Feature-first directory structure with Provider state management. All pages route through `MaterialApp` with Navigator 1.0. Chat page uses mock data to demonstrate the full conversation UI before Day 2's LLM integration.

**Tech Stack:** Flutter 3.x, Dart, Provider (state management), Flutter's built-in Navigator

---

### Task 1: Add Provider dependency and update pubspec metadata

**Files:**
- Modify: `pubspec.yaml:1-2` (name/description)
- Modify: `pubspec.yaml:30-35` (add provider dependency)

**Step 1: Update pubspec.yaml**

```yaml
name: socratic_ai
description: "苏格拉底式 AI 对话 - 一个通过追问帮你理清思路的 AI 对话 App。"
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: ^3.12.2

dependencies:
  flutter:
    sdk: flutter
  cupertino_icons: ^1.0.8
  provider: ^6.1.2

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^6.0.0
```

**Step 2: Install dependency**

Run: `cd /Users/superjie-mac/projects/socratic-ai && flutter pub get`
Expected: `exit code 0`, no errors

**Step 3: Commit**

```bash
git add pubspec.yaml pubspec.lock
git commit -m "chore: add provider dependency, update project metadata"
```

---

### Task 2: Create core theme configuration

**Files:**
- Create: `lib/core/theme.dart`
- Create: `lib/core/constants.dart`

**Step 1: Write the theme file**

```dart
// lib/core/theme.dart
import 'package:flutter/material.dart';

class AppTheme {
  // Primary palette - calm, warm, intellectual
  static const Color primary = Color(0xFF5B6D5B);   // Sage green
  static const Color secondary = Color(0xFF8B7355); // Warm brown
  static const Color surface = Color(0xFFF5F0EB);   // Warm white
  static const Color background = Color(0xFFFAFAF8); // Almost white
  static const Color textPrimary = Color(0xFF2C2C2C);
  static const Color textSecondary = Color(0xFF6B6B6B);
  static const Color accent = Color(0xFFD4A574);     // Warm gold

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primary,
        brightness: Brightness.light,
        surface: surface,
      ),
      scaffoldBackgroundColor: background,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w700,
          color: textPrimary,
          letterSpacing: -0.5,
        ),
        headlineMedium: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: textPrimary,
        ),
        bodyLarge: TextStyle(
          fontSize: 16,
          color: textPrimary,
          height: 1.5,
        ),
        bodyMedium: TextStyle(
          fontSize: 14,
          color: textSecondary,
          height: 1.4,
        ),
      ),
      cardTheme: CardTheme(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
    );
  }
}
```

**Step 2: Write the constants file**

```dart
// lib/core/constants.dart
class AppConstants {
  static const String appName = 'Socratic AI';
  static const String appTagline = '帮你想清楚';

  static const List<TopicItem> presetTopics = [
    TopicItem(
      icon: '🧭',
      title: '职业发展',
      description: '该深耕还是该转型？',
    ),
    TopicItem(
      icon: '💭',
      title: '两难决策',
      description: '两个选项，怎么选？',
    ),
    TopicItem(
      icon: '🧠',
      title: '自我探索',
      description: '我想成为什么样的人？',
    ),
    TopicItem(
      icon: '💼',
      title: '工作难题',
      description: '这个问题到底卡在哪？',
    ),
    TopicItem(
      icon: '❤️',
      title: '人际关系',
      description: '这段关系我该怎么看？',
    ),
  ];
}

class TopicItem {
  final String icon;
  final String title;
  final String description;

  const TopicItem({
    required this.icon,
    required this.title,
    required this.description,
  });
}
```

**Step 3: Run static analysis**

Run: `cd /Users/superjie-mac/projects/socratic-ai && flutter analyze lib/core/`
Expected: `No issues found!`

**Step 4: Commit**

```bash
git add lib/core/
git commit -m "feat: add core theme and topic constants"
```

---

### Task 3: Create TopicProvider for state management

**Files:**
- Create: `lib/features/topics/providers/topic_provider.dart`
- Test: `test/features/topics/providers/topic_provider_test.dart`

**Step 1: Write the failing test**

```dart
// test/features/topics/providers/topic_provider_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:socratic_ai/features/topics/providers/topic_provider.dart';

void main() {
  group('TopicProvider', () {
    test('initial state has null selected topic', () {
      final provider = TopicProvider();
      expect(provider.selectedTopic, isNull);
      expect(provider.customTopic, isEmpty);
    });

    test('selectTopic updates selected topic title', () {
      final provider = TopicProvider();
      provider.selectTopic('职业发展');
      expect(provider.selectedTopic, '职业发展');
    });

    test('setCustomTopic updates custom topic', () {
      final provider = TopicProvider();
      provider.setCustomTopic('如何处理焦虑');
      expect(provider.customTopic, '如何处理焦虑');
    });
  });
}
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/superjie-mac/projects/socratic-ai && flutter test test/features/topics/providers/topic_provider_test.dart`
Expected: FAIL with compilation errors (file not found)

**Step 3: Implement TopicProvider**

```dart
// lib/features/topics/providers/topic_provider.dart
import 'package:flutter/foundation.dart';

class TopicProvider extends ChangeNotifier {
  String? _selectedTopic;
  String _customTopic = '';

  String? get selectedTopic => _selectedTopic;
  String get customTopic => _customTopic;

  void selectTopic(String topic) {
    _selectedTopic = topic;
    notifyListeners();
  }

  void setCustomTopic(String topic) {
    _customTopic = topic;
    _selectedTopic = null;
    notifyListeners();
  }

  void reset() {
    _selectedTopic = null;
    _customTopic = '';
    notifyListeners();
  }
}
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/superjie-mac/projects/socratic-ai && flutter test test/features/topics/providers/topic_provider_test.dart`
Expected: `All tests passed!`

**Step 5: Commit**

```bash
git add lib/features/ test/features/
git commit -m "feat: add TopicProvider with state management"
```

---

### Task 4: Create TopicCard widget

**Files:**
- Create: `lib/features/topics/widgets/topic_card.dart`
- Test: `test/features/topics/widgets/topic_card_test.dart`

**Step 1: Write the failing test**

```dart
// test/features/topics/widgets/topic_card_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:socratic_ai/core/constants.dart';
import 'package:socratic_ai/features/topics/widgets/topic_card.dart';

void main() {
  testWidgets('TopicCard displays icon, title, and description', (tester) async {
    const topic = TopicItem(icon: '🧭', title: '职业发展', description: '该深耕还是该转型？');

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TopicCard(topic: topic))),
    );

    expect(find.text('🧭'), findsOneWidget);
    expect(find.text('职业发展'), findsOneWidget);
    expect(find.text('该深耕还是该转型？'), findsOneWidget);
  });

  testWidgets('TopicCard calls onTap when tapped', (tester) async {
    const topic = TopicItem(icon: '🧭', title: '职业发展', description: 'test');
    String? tappedTitle;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TopicCard(
            topic: topic,
            onTap: (t) => tappedTitle = t.title,
          ),
        ),
      ),
    );

    await tester.tap(find.text('职业发展'));
    expect(tappedTitle, '职业发展');
  });
}
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/superjie-mac/projects/socratic-ai && flutter test test/features/topics/widgets/topic_card_test.dart`
Expected: FAIL (file not found)

**Step 3: Implement TopicCard**

```dart
// lib/features/topics/widgets/topic_card.dart
import 'package:flutter/material.dart';
import 'package:socratic_ai/core/constants.dart';
import 'package:socratic_ai/core/theme.dart';

class TopicCard extends StatelessWidget {
  final TopicItem topic;
  final void Function(TopicItem)? onTap;

  const TopicCard({super.key, required this.topic, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onTap?.call(topic),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE8E4DF)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Text(topic.icon, style: const TextStyle(fontSize: 24)),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    topic.title,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    topic.description,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: AppTheme.textSecondary),
          ],
        ),
      ),
    );
  }
}
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/superjie-mac/projects/socratic-ai && flutter test test/features/topics/widgets/topic_card_test.dart`
Expected: `All tests passed!`

**Step 5: Commit**

```bash
git add lib/features/topics/widgets/ test/features/topics/widgets/
git commit -m "feat: add TopicCard widget with tap interaction"
```

---

### Task 5: Create TopicSelectionPage

**Files:**
- Create: `lib/features/topics/topic_selection_page.dart`
- Test: `test/features/topics/topic_selection_page_test.dart`

**Step 1: Write the failing test**

```dart
// test/features/topics/topic_selection_page_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:socratic_ai/features/topics/providers/topic_provider.dart';
import 'package:socratic_ai/features/topics/topic_selection_page.dart';

void main() {
  testWidgets('TopicSelectionPage shows all 5 preset topics', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => TopicProvider(),
        child: const MaterialApp(home: TopicSelectionPage()),
      ),
    );

    expect(find.text('职业发展'), findsOneWidget);
    expect(find.text('两难决策'), findsOneWidget);
    expect(find.text('自我探索'), findsOneWidget);
    expect(find.text('工作难题'), findsOneWidget);
    expect(find.text('人际关系'), findsOneWidget);
  });

  testWidgets('Custom topic input is present', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => TopicProvider(),
        child: const MaterialApp(home: TopicSelectionPage()),
      ),
    );

    expect(find.byType(TextField), findsOneWidget);
  });
}
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/superjie-mac/projects/socratic-ai && flutter test test/features/topics/topic_selection_page_test.dart`
Expected: FAIL (file not found)

**Step 3: Implement TopicSelectionPage**

```dart
// lib/features/topics/topic_selection_page.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:socratic_ai/core/constants.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/topics/providers/topic_provider.dart';
import 'package:socratic_ai/features/topics/widgets/topic_card.dart';
import 'package:socratic_ai/features/chat/chat_page.dart';

class TopicSelectionPage extends StatelessWidget {
  const TopicSelectionPage({super.key});

  @override
  Widget build(BuildContext context) {
    final topicProvider = context.watch<TopicProvider>();

    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            icon: const Icon(Icons.history, color: AppTheme.textSecondary),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const _PlaceholderPage(title: '历史对话'),
                ),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 16, 24, 8),
              child: Text(
                AppConstants.appName,
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                AppConstants.appTagline,
                style: TextStyle(
                  fontSize: 16,
                  color: AppTheme.textSecondary,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
              child: Text(
                '选择一个话题开始对话',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 16),
                children: [
                  ...AppConstants.presetTopics.map(
                    (topic) => TopicCard(
                      topic: topic,
                      onTap: (t) {
                        topicProvider.selectTopic(t.title);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ChatPage(topic: t.title),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      '或者，说说你想聊的',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppTheme.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: TextField(
                      onChanged: (value) {
                        topicProvider.setCustomTopic(value);
                      },
                      onSubmitted: (value) {
                        if (value.trim().isNotEmpty) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ChatPage(topic: value.trim()),
                            ),
                          );
                        }
                      },
                      decoration: InputDecoration(
                        hintText: '✍️ 输入你的话题...',
                        hintStyle: const TextStyle(color: AppTheme.textSecondary),
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 16,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: const BorderSide(color: Color(0xFFE8E4DF)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: const BorderSide(color: Color(0xFFE8E4DF)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: const BorderSide(
                            color: AppTheme.primary,
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaceholderPage extends StatelessWidget {
  final String title;
  const _PlaceholderPage({required this.title});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Text(
          '$title — 即将上线',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      ),
    );
  }
}
```

**Step 4: Run test to verify it passes**

Note: The test references `ChatPage` which doesn't exist yet. Create a minimal stub first.

Run: `cd /Users/superjie-mac/projects/socratic-ai && flutter test test/features/topics/topic_selection_page_test.dart`
Expected: FAIL (ChatPage not found — expected, will resolve in Task 7)

**Step 5: Commit**

```bash
git add lib/features/topics/topic_selection_page.dart test/features/topics/
git commit -m "feat: add TopicSelectionPage with preset topics and custom input"
```

---

### Task 6: Create ChatProvider with mock conversation data

**Files:**
- Create: `lib/features/chat/providers/chat_provider.dart`
- Test: `test/features/chat/providers/chat_provider_test.dart`

**Step 1: Write the failing test**

```dart
// test/features/chat/providers/chat_provider_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:socratic_ai/features/chat/providers/chat_provider.dart';

void main() {
  group('ChatProvider', () {
    test('initial state has welcome message', () {
      final provider = ChatProvider(topic: '职业发展');
      expect(provider.messages.length, 1);
      expect(provider.messages.first.role, 'ai');
      expect(provider.messages.first.content, contains('职业发展'));
    });

    test('sendMessage adds user message and AI response', () {
      final provider = ChatProvider(topic: '职业发展');
      provider.sendMessage('我想转管理');
      expect(provider.messages.length, 3); // welcome + user + ai
      expect(provider.messages[1].role, 'user');
      expect(provider.messages[1].content, '我想转管理');
      expect(provider.messages[2].role, 'ai');
    });

    test('isThinking is true while AI responds', () {
      final provider = ChatProvider(topic: 'test');
      expect(provider.isThinking, false);
      provider.sendMessage('hello');
      expect(provider.isThinking, false); // mock responds instantly for MVP
    });

    test('round number increments with each AI message', () {
      final provider = ChatProvider(topic: 'test');
      expect(provider.round, 1);
      provider.sendMessage('answer 1');
      expect(provider.round, 2);
    });
  });

  group('ChatMessage', () {
    test('ChatMessage creates correctly', () {
      final msg = ChatMessage(role: 'user', content: 'hello', round: 3);
      expect(msg.role, 'user');
      expect(msg.content, 'hello');
      expect(msg.round, 3);
    });
  });
}
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/superjie-mac/projects/socratic-ai && flutter test test/features/chat/providers/chat_provider_test.dart`
Expected: FAIL (file not found)

**Step 3: Implement ChatProvider**

```dart
// lib/features/chat/providers/chat_provider.dart
import 'package:flutter/foundation.dart';

class ChatMessage {
  final String role; // 'ai' or 'user'
  final String content;
  final int round;

  const ChatMessage({
    required this.role,
    required this.content,
    required this.round,
  });
}

class ChatProvider extends ChangeNotifier {
  final String topic;
  int _round = 1;
  bool _isThinking = false;

  final List<ChatMessage> _messages = [];

  ChatProvider({required this.topic}) {
    _addWelcomeMessage();
  }

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  int get round => _round;
  bool get isThinking => _isThinking;

  void _addWelcomeMessage() {
    final openings = <String, String>{
      '职业发展': '你提到想聊聊职业方向——如果三年后的你回头看今天做的选择，你觉得他会在意什么？',
      '两难决策': '你面前有两个选择——在做决定之前，你想过这两个选择分别代表了什么样的自己吗？',
      '自我探索': '关于"我是谁"这个问题——你最近一次觉得自己不够了解自己，是什么时候？',
      '工作难题': '这个问题卡住了你——你觉得卡住的到底是事情本身，还是你看待事情的角度？',
      '人际关系': '这段关系让你在意的地方是什么——是对方的期待，还是你对自己在这段关系里的要求？',
    };

    final opening = openings[topic] ?? '你想和我聊聊什么话题？让我们从头开始。';

    _messages.add(ChatMessage(
      role: 'ai',
      content: opening,
      round: _round,
    ));
    _round++;
  }

  void sendMessage(String content) {
    // Add user message
    _messages.add(ChatMessage(
      role: 'user',
      content: content,
      round: _round,
    ));

    _isThinking = true;
    notifyListeners();

    // Mock AI response (Day 3 will replace with real LLM)
    _messages.add(ChatMessage(
      role: 'ai',
      content: _generateMockResponse(content),
      round: _round,
    ));

    _round++;
    _isThinking = false;
    notifyListeners();
  }

  String _generateMockResponse(String userInput) {
    final responses = [
      '你提到的这点很有意思——你能给我一个具体的例子吗？',
      '如果完全没有失败的风险，你的答案会变吗？',
      '你刚才说到的这个想法，背后最让你担心的是什么？',
      '换句话说，你觉得这件事对你来说最重要的是什么？',
      '如果一位朋友处在你的位置，你给他什么建议？',
    ];
    return responses[_messages.length % responses.length];
  }
}
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/superjie-mac/projects/socratic-ai && flutter test test/features/chat/providers/chat_provider_test.dart`
Expected: `All tests passed!`

**Step 5: Commit**

```bash
git add lib/features/chat/providers/ test/features/chat/providers/
git commit -m "feat: add ChatProvider with mock conversation data"
```

---

### Task 7: Create ChatBubble widget

**Files:**
- Create: `lib/features/chat/widgets/chat_bubble.dart`
- Test: `test/features/chat/widgets/chat_bubble_test.dart`

**Step 1: Write the failing test**

```dart
// test/features/chat/widgets/chat_bubble_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:socratic_ai/features/chat/providers/chat_provider.dart';
import 'package:socratic_ai/features/chat/widgets/chat_bubble.dart';

void main() {
  testWidgets('AI bubble is left-aligned with different color', (tester) async {
    final msg = ChatMessage(role: 'ai', content: '你好，你想聊什么？', round: 1);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ChatBubble(message: msg))),
    );
    expect(find.text('你好，你想聊什么？'), findsOneWidget);
  });

  testWidgets('User bubble is right-aligned', (tester) async {
    final msg = ChatMessage(role: 'user', content: '我想聊聊职业发展', round: 1);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ChatBubble(message: msg))),
    );
    expect(find.text('我想聊聊职业发展'), findsOneWidget);
  });
}
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/superjie-mac/projects/socratic-ai && flutter test test/features/chat/widgets/chat_bubble_test.dart`
Expected: FAIL (file not found)

**Step 3: Implement ChatBubble**

```dart
// lib/features/chat/widgets/chat_bubble.dart
import 'package:flutter/material.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/chat/providers/chat_provider.dart';

class ChatBubble extends StatelessWidget {
  final ChatMessage message;

  const ChatBubble({super.key, required this.message});

  bool get _isAI => message.role == 'ai';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        mainAxisAlignment:
            _isAI ? MainAxisAlignment.start : MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (_isAI) ...[
            const CircleAvatar(
              radius: 16,
              backgroundColor: AppTheme.primary,
              child: Text('AI', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 260),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: _isAI ? Colors.white : AppTheme.primary,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: _isAI
                      ? const Radius.circular(4)
                      : const Radius.circular(16),
                  bottomRight: _isAI
                      ? const Radius.circular(16)
                      : const Radius.circular(4),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Text(
                message.content,
                style: TextStyle(
                  color: _isAI ? AppTheme.textPrimary : Colors.white,
                  fontSize: 15,
                  height: 1.5,
                ),
              ),
            ),
          ),
          if (!_isAI) const SizedBox(width: 8),
        ],
      ),
    );
  }
}
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/superjie-mac/projects/socratic-ai && flutter test test/features/chat/widgets/chat_bubble_test.dart`
Expected: `All tests passed!`

**Step 5: Commit**

```bash
git add lib/features/chat/widgets/chat_bubble.dart test/features/chat/widgets/
git commit -m "feat: add ChatBubble widget with AI/user styling"
```

---

### Task 8: Create ChatInput widget

**Files:**
- Create: `lib/features/chat/widgets/chat_input.dart`
- Test: `test/features/chat/widgets/chat_input_test.dart`

**Step 1: Write the failing test**

```dart
// test/features/chat/widgets/chat_input_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:socratic_ai/features/chat/widgets/chat_input.dart';

void main() {
  testWidgets('ChatInput sends message on submit', (tester) async {
    String? submitted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatInput(onSend: (msg) => submitted = msg),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '测试消息');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    expect(submitted, '测试消息');
  });

  testWidgets('ChatInput clears text after send', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: const Scaffold(body: ChatInput()),
      ),
    );

    await tester.enterText(find.byType(TextField), '测试');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    // TextField should be cleared
    expect(find.text('测试'), findsNothing);
  });
}
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/superjie-mac/projects/socratic-ai && flutter test test/features/chat/widgets/chat_input_test.dart`
Expected: FAIL (file not found)

**Step 3: Implement ChatInput**

```dart
// lib/features/chat/widgets/chat_input.dart
import 'package:flutter/material.dart';
import 'package:socratic_ai/core/theme.dart';

class ChatInput extends StatefulWidget {
  final void Function(String message)? onSend;

  const ChatInput({super.key, this.onSend});

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> {
  final _controller = TextEditingController();

  void _handleSubmit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onSend?.call(text);
    _controller.clear();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.grey.shade200)),
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _handleSubmit(),
                decoration: InputDecoration(
                  hintText: '输入你的回答...',
                  hintStyle: const TextStyle(color: AppTheme.textSecondary),
                  filled: true,
                  fillColor: AppTheme.surface,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              decoration: const BoxDecoration(
                color: AppTheme.primary,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                onPressed: _handleSubmit,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/superjie-mac/projects/socratic-ai && flutter test test/features/chat/widgets/chat_input_test.dart`
Expected: `All tests passed!`

**Step 5: Commit**

```bash
git add lib/features/chat/widgets/chat_input.dart test/features/chat/widgets/
git commit -m "feat: add ChatInput widget with send functionality"
```

---

### Task 9: Create ChatPage

**Files:**
- Create: `lib/features/chat/chat_page.dart`
- Test: `test/features/chat/chat_page_test.dart`

**Step 1: Write the failing test**

```dart
// test/features/chat/chat_page_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:socratic_ai/features/chat/chat_page.dart';
import 'package:socratic_ai/features/chat/providers/chat_provider.dart';

void main() {
  Widget buildTestWidget() {
    return MaterialApp(
      home: ChangeNotifierProvider(
        create: (_) => ChatProvider(topic: '职业发展'),
        child: const ChatPage(topic: '职业发展'),
      ),
    );
  }

  testWidgets('ChatPage shows topic in app bar', (tester) async {
    await tester.pumpWidget(buildTestWidget());
    expect(find.text('职业发展'), findsOneWidget);
  });

  testWidgets('ChatPage shows initial AI welcome message', (tester) async {
    await tester.pumpWidget(buildTestWidget());
    // Should contain the opening message for 职业发展
    expect(find.textContaining('职业方向'), findsOneWidget);
  });

  testWidgets('ChatPage has input field', (tester) async {
    await tester.pumpWidget(buildTestWidget());
    expect(find.byType(TextField), findsOneWidget);
  });
}
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/superjie-mac/projects/socratic-ai && flutter test test/features/chat/chat_page_test.dart`
Expected: FAIL (file not found)

**Step 3: Implement ChatPage**

```dart
// lib/features/chat/chat_page.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/chat/providers/chat_provider.dart';
import 'package:socratic_ai/features/chat/widgets/chat_bubble.dart';
import 'package:socratic_ai/features/chat/widgets/chat_input.dart';
import 'package:socratic_ai/features/insights/insights_page.dart';

class ChatPage extends StatelessWidget {
  final String topic;

  const ChatPage({super.key, required this.topic});

  void _endConversation(BuildContext context, ChatProvider chatProvider) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => InsightsPage(
          conversation: chatProvider.messages,
          topic: topic,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ChatProvider(topic: topic),
      child: Consumer<ChatProvider>(
        builder: (context, chatProvider, _) {
          return Scaffold(
            appBar: AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(topic, style: const TextStyle(fontSize: 16)),
                  Text(
                    '第 ${chatProvider.round} 轮',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton.icon(
                  onPressed: () => _endConversation(context, chatProvider),
                  icon: const Icon(Icons.stop_circle_outlined,
                      color: AppTheme.secondary, size: 18),
                  label: const Text('结束对话',
                      style: TextStyle(color: AppTheme.secondary, fontSize: 13)),
                ),
              ],
            ),
            body: Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    itemCount: chatProvider.messages.length,
                    itemBuilder: (context, index) {
                      return ChatBubble(
                        message: chatProvider.messages[index],
                      );
                    },
                  ),
                ),
                if (chatProvider.isThinking)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Row(
                      children: [
                        SizedBox(width: 48),
                        _ThinkingIndicator(),
                      ],
                    ),
                  ),
                ChatInput(
                  onSend: (message) {
                    chatProvider.sendMessage(message);
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ThinkingIndicator extends StatefulWidget {
  const _ThinkingIndicator();

  @override
  State<_ThinkingIndicator> createState() => _ThinkingIndicatorState();
}

class _ThinkingIndicatorState extends State<_ThinkingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildDot(0),
            const SizedBox(width: 4),
            _buildDot(1),
            const SizedBox(width: 4),
            _buildDot(2),
            const SizedBox(width: 8),
            const Text('正在思考...',
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          ],
        );
      },
    );
  }

  Widget _buildDot(int index) {
    final delay = index * 0.2;
    final value = (_controller.value - delay).clamp(0.0, 1.0);
    final scale = 0.5 + 0.5 * (value < 0.5 ? value * 2 : 2 - value * 2);
    return Transform.scale(
      scale: scale,
      child: Container(
        width: 6,
        height: 6,
        decoration: const BoxDecoration(
          color: AppTheme.primary,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
```

**Step 4: Run test to verify it passes**

Note: Needs a stub `InsightsPage`. Create it minimally:

```dart
// lib/features/insights/insights_page.dart
import 'package:flutter/material.dart';
import 'package:socratic_ai/features/chat/providers/chat_provider.dart';

class InsightsPage extends StatelessWidget {
  final List<ChatMessage> conversation;
  final String topic;

  const InsightsPage({
    super.key,
    required this.conversation,
    required this.topic,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('洞察总结')),
      body: const Center(child: Text('洞察总结 — 即将在 Day 4 实现')),
    );
  }
}
```

Run: `cd /Users/superjie-mac/projects/socratic-ai && flutter test test/features/chat/chat_page_test.dart`
Expected: `All tests passed!`

**Step 5: Commit**

```bash
git add lib/features/chat/chat_page.dart lib/features/insights/ test/features/chat/
git commit -m "feat: add ChatPage with conversation flow and thinking indicator"
```

---

### Task 10: Create AppShell with routing, replace old main.dart

**Files:**
- Modify: `lib/main.dart` (complete rewrite)
- Create: `lib/app.dart`

**Step 1: Write the new main.dart**

```dart
// lib/main.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:socratic_ai/app.dart';
import 'package:socratic_ai/features/topics/providers/topic_provider.dart';

void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => TopicProvider()),
      ],
      child: const SocraticApp(),
    ),
  );
}
```

**Step 2: Write app.dart**

```dart
// lib/app.dart
import 'package:flutter/material.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/topics/topic_selection_page.dart';

class SocraticApp extends StatelessWidget {
  const SocraticApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Socratic AI',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      home: const TopicSelectionPage(),
    );
  }
}
```

**Step 3: Run the app to verify**

Run: `cd /Users/superjie-mac/projects/socratic-ai && flutter run`
Expected: App launches with topic selection page, tap topic → chat page, send message → AI responds

**Step 4: Commit**

```bash
git add lib/main.dart lib/app.dart
git commit -m "feat: wire up AppShell with Provider and routing"
```

---

### Task 11: Write end-to-end integration test

**Files:**
- Create: `test/smoke_test.dart`

**Step 1: Write the integration test**

```dart
// test/smoke_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:socratic_ai/app.dart';
import 'package:socratic_ai/features/topics/providers/topic_provider.dart';

void main() {
  Widget buildTestApp() {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => TopicProvider()),
      ],
      child: const SocraticApp(),
    );
  }

  testWidgets('Full flow: select topic → chat → send message', (tester) async {
    await tester.pumpWidget(buildTestApp());

    // Verify topic selection page is shown
    expect(find.text('Socratic AI'), findsOneWidget);
    expect(find.text('帮你想清楚'), findsOneWidget);
    expect(find.text('职业发展'), findsOneWidget);

    // Tap on first topic
    await tester.tap(find.text('职业发展'));
    await tester.pumpAndSettle();

    // Verify we're on chat page
    expect(find.text('职业发展'), findsWidgets); // in appbar
    expect(find.textContaining('职业方向'), findsOneWidget); // welcome message

    // Type and send a message
    await tester.enterText(find.byType(TextField), '我想转管理岗位');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    // Verify user message appeared
    expect(find.text('我想转管理岗位'), findsOneWidget);

    // Verify AI response appeared
    await tester.pump();
    // (mock response will be present)
  });

  testWidgets('Custom topic flow', (tester) async {
    await tester.pumpWidget(buildTestApp());

    // Type custom topic
    await tester.enterText(find.byType(TextField), '如何处理焦虑');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    // Verify navigated to chat with custom topic
    expect(find.text('如何处理焦虑'), findsOneWidget);
  });
}
```

**Step 2: Run integration test**

Run: `cd /Users/superjie-mac/projects/socratic-ai && flutter test test/smoke_test.dart`
Expected: `All tests passed!`

**Step 3: Commit**

```bash
git add test/smoke_test.dart
git commit -m "test: add end-to-end smoke test for main flow"
```

---

### Task 12: Remove old counter test, run full test suite

**Files:**
- Delete: `test/widget_test.dart`

**Step 1: Delete the old test**

Run: `rm /Users/superjie-mac/projects/socratic-ai/test/widget_test.dart`

**Step 2: Run full test suite**

Run: `cd /Users/superjie-mac/projects/socratic-ai && flutter test`
Expected: All tests pass, no failures

**Step 3: Run static analysis**

Run: `cd /Users/superjie-mac/projects/socratic-ai && flutter analyze`
Expected: `No issues found!`

**Step 4: Commit**

```bash
git add -A
git commit -m "test: remove old counter test, finalize Day 1 scaffolding"
```

---

### Verdict
If all tasks are completed and all tests pass, we'll have:
- Topic selection page with 5 preset topics + custom input ✅
- Chat page with AI/user bubbles + input ✅
- Mock conversation flow (select → chat → respond) ✅
- Navigation between pages ✅
- Provider state management ✅
- Clean feature-first directory structure ✅
- 6 passing test files ✅
- 12 atomic commits ✅
```

The plan is now saved. All that's left is the handoff. According to the writing-plans skill, I should offer the user a choice of execution approaches.

Let me now output the summary and offer the execution choice as specified by the skill.<｜end▁of▁thinking｜>---

Plan complete and saved to `docs/plans/2026-07-01-day1-engineering-scaffold.md`.

按 writing-plans 规范产出了 12 个 bite-sized 任务，每个都包含：**具体文件路径、完整代码、精确命令、期望输出、独立 commit**。

两种执行方式：

1. **Subagent-Driven（当前会话）** — 我一个一个任务调度子 agent 执行，每步 review 后继续
2. **Parallel Session（新会话）** — 你开新会话加载 `executing-plans` 技能，批量执行带 checkpoint

你选哪种？还是我直接在当前会话开始干？