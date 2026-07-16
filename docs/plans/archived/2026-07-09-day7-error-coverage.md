# Day 7 — 错误覆盖与状态矩阵 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 实现 PRD 状态矩阵全覆盖（模型加载失败 / AI 推理失败 / 数据库失败等），补齐边界 case（空话题 / 超长回答），Android 真机验证。

**Architecture:** 每个 Provider 新增 `error` 状态字段 → Page 层根据 `error` 渲染对应 UI（错误页 + 重试按钮 / SnackBar / 兜底消息）。状态提升到 Provider，Page 只做渲染判断，不自行发起异步调用。

**Tech Stack:** Flutter 3.x + Provider + sqflite + llama_cpp_dart

**前置发现：**
- 收藏/星标功能已在 Day 5 完整实现（Conversation.isFavorite + Repository.toggleFavorite + ConversationCard 星标图标 + HistoryPage 回调），Day 7 无需再处理收藏 UI。
- Android 平台检查已就绪（llama_service.dart 中 `libllama.so` 加载路径），缺少的是真机验证和 UI 适配。

---

## 已完成状态矩阵梳理（本次无需改动）

| 状态 | 实现位置 | 是否完整 |
|------|---------|:--:|
| 模型加载中 | ChatPage: 全屏 CircularProgressIndicator + "正在加载 AI 模型" | ✅ |
| 等待用户输入 | ChatPage: 输入框可用，光标闪烁 | ✅ |
| AI 思考中 | ChatPage: `_ThinkingIndicator` 三点呼吸动画 | ✅ |
| 对话正常 | ChatPage: 聊天气泡正常展示 | ✅ |
| 洞察生成中 | ChatPage: Modal Dialog + "正在生成洞察总结..." | ✅ |
| 历史列表加载中 | HistoryPage: 居中 CircularProgressIndicator | ✅ |
| 历史列表空 | HistoryPage: `_buildEmptyState()` | ✅ |
| 洞察空 | InsightsPage: `_buildEmptyState()` | ✅ |
| 图谱加载中 | MindMapService: Modal Dialog | ✅ |
| 图谱空 | MindMapPage: `_buildEmptyState()` | ✅ |
| 图谱生成失败 | MindMapService: SnackBar "图谱生成失败: $e" | ✅ |

## 待补齐状态（本次实现目标）

| 状态 | 当前表现 | 目标 |
|------|---------|------|
| **模型加载失败** | `_modelError` 存储但 UI 不展示 | ChatPage 展示错误页 + 重试按钮 |
| **AI 推理失败** | catch 内生成一条友好文字回复 | 保持现状 + 加 SnackBar 提醒用户 |
| **数据库加载失败** | catch 内 `debugPrint` 后静默 | HistoryPage 展示错误页 + 重试按钮 |
| **数据库写入失败** | 无 catch | 加 try-catch + SnackBar |
| **空话题输入** | 未校验 | 空字符串/纯空格拦截 + SnackBar 提示 |
| **超长回答** | 无限制 | 3000 字符上限 + 提示 |
| **JSON 解析失败（洞察）** | 三层回退 + 兜底 | 保持（已够用） |
| **JSON 解析失败（图谱）** | 三层回退 + 返回空图谱 | 保持（已够用） |

---

### Task 1: ChatProvider 模型加载错误状态提升

**Files:**
- Modify: `lib/features/chat/providers/chat_provider.dart`

**ChatProvider 已有 `_modelError` 字段，但缺少：**
1. 公开 getter 让 Page 读取错误
2. `retry()` 方法供重试按钮调用
3. 错误状态清除（重试时重置）

**Step 1: 添加公开 getter 和 retry 方法**

在 `chat_provider.dart` 中：

```dart
// 公开 getter（在现有 _modelError 字段下方）
String? get modelError => _modelError;
bool get hasModelError => _modelError != null;
bool _isRetrying = false;

// retry 方法
Future<void> retryLoadModel() async {
  _modelError = null;
  _isLoading = true;
  notifyListeners();

  try {
    final llmEngine = await LlamaService.instance.ensureReady();
    _prompter = SocraticPrompter(llmEngine);
    await _prompter.initialize();
    _isLoaded = true;
    _isLoading = false;
    notifyListeners();
  } catch (e) {
    debugPrint('[ChatProvider] 模型加载重试失败: $e');
    _modelError = e.toString();
    _isLoading = false;
    notifyListeners();
  }
}
```

注意：由于 `ensureReady()` 现在返回 `Future<LlamaEngine>`，需要调整 retry 逻辑适配 Day 6a 重构后的 API。检查 `chat_provider.dart` 中现有的 `_loadModel()` 方法签名，retry 复用相同逻辑。

**Step 2: 运行分析确认无编译错误**

```bash
cd /Users/superjie-mac/projects/socratic-ai && flutter analyze lib/features/chat/providers/chat_provider.dart
```

**Step 3: 提交**

```bash
git add lib/features/chat/providers/chat_provider.dart
git commit -m "feat(chat): add modelError getter + retryLoadModel to ChatProvider"
```

---

### Task 2: ChatPage 模型加载失败 UI

**Files:**
- Modify: `lib/features/chat/chat_page.dart`

**需求：** 当 `chatProvider.hasModelError` 时，展示错误页替代加载页。

**Step 1: 添加错误状态渲染**

在 `chat_page.dart` 的 `build()` 方法中，在 `isModelLoading` 判断之后插入错误判断：

```dart
if (chatProvider.hasModelError) {
  return _buildModelErrorView(chatProvider);
}
```

**Step 2: 实现 `_buildModelErrorView` 方法**

```dart
Widget _buildModelErrorView(ChatProvider provider) {
  return Scaffold(
    appBar: AppBar(title: Text(widget.topic)),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 64, color: AppTheme.error),
            const SizedBox(height: 16),
            const Text(
              'AI 模型加载失败',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              '请确保设备有足够存储空间并重试',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => provider.retryLoadModel(),
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('返回'),
            ),
          ],
        ),
      ),
    ),
  );
}
```

**Step 3: 运行分析确认无编译错误**

```bash
cd /Users/superjie-mac/projects/socratic-ai && flutter analyze lib/features/chat/chat_page.dart
```

**Step 4: 提交**

```bash
git add lib/features/chat/chat_page.dart
git commit -m "feat(chat): add model error view with retry button in ChatPage"
```

---

### Task 3: ChatProvider 推理失败 SnackBar 提醒

**Files:**
- Modify: `lib/features/chat/providers/chat_provider.dart`
- Modify: `lib/features/chat/chat_page.dart`

**需求：** AI 推理失败时，当前只生成一条友好文字回复。额外通过 SnackBar 告知用户"当前回复为兜底内容"。

**Step 1: ChatProvider 新增错误回调**

在 `chat_provider.dart` 顶部定义回调类型，或在 `sendMessage` 中将错误信息返回给调用方：

```dart
// 在 sendMessage 的 catch 块中，不改变现有逻辑，只额外返回错误标记
// 当前 catch 块：
catch (e) {
  debugPrint('[ChatProvider] LLM 推理失败，使用 Mock 回复: $e');
  final fallback = ChatMessage(
    role: MessageRole.ai,
    content: '抱歉，我在思考时遇到了一些问题。让我换一种方式继续追问：你能再多说说你的想法吗？',
    roundNumber: ++_currentRound,
  );
  _messages.add(fallback);
  _isThinking = false;
  _error = e.toString();  // 新增
  notifyListeners();
}
```

**Step 2: 添加 error getter 和 clearError**

```dart
String? get error => _error;
void clearError() { _error = null; }
```

**Step 3: ChatPage 监听 error 变化并展示 SnackBar**

在 `chat_page.dart` 的 `initState` 中（或 didChangeDependencies）：

```dart
// 添加 listener
void _onError() {
  final error = context.read<ChatProvider>().error;
  if (error != null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('AI 推理遇到问题，当前为兜底回复'),
        backgroundColor: AppTheme.warning,
        behavior: SnackBarBehavior.floating,
      ),
    );
    context.read<ChatProvider>().clearError();
  }
}
```

需要在 `initState` 中 `addListener(_onError)`，在 `dispose` 中 `removeListener(_onError)`。

**Step 4: 运行分析**

```bash
cd /Users/superjie-mac/projects/socratic-ai && flutter analyze lib/features/chat/
```

**Step 5: 提交**

```bash
git add lib/features/chat/providers/chat_provider.dart lib/features/chat/chat_page.dart
git commit -m "feat(chat): add inference error SnackBar notification"
```

---

### Task 4: ConversationProvider 数据库错误状态

**Files:**
- Modify: `lib/features/history/providers/conversation_provider.dart`

**需求：** 数据库操作失败时暴露 `error` 状态，让 HistoryPage 展示错误 UI。

**Step 1: 添加 error 字段和 getter**

```dart
String? _error;
String? get error => _error;
bool get hasError => _error != null;
```

**Step 2: 在 loadAll 中捕获并存储错误**

```dart
Future<void> loadAll() async {
  _isLoading = true;
  _error = null;
  notifyListeners();

  try {
    _conversations = await _repo.listAll();
  } catch (e) {
    debugPrint('[ConversationProvider] 加载失败: $e');
    _error = '无法加载对话记录，请检查存储空间后重试';
    _conversations = [];
  } finally {
    _isLoading = false;
    notifyListeners();
  }
}
```

**Step 3: 添加 retry 方法**

```dart
Future<void> retry() async {
  await loadAll();
}
```

**Step 4: 在 deleteConversation / toggleFavorite 等写操作中捕获错误**

```dart
Future<void> deleteConversation(int id) async {
  try {
    await _repo.delete(id);
    _conversations.removeWhere((c) => c.id == id);
    notifyListeners();
  } catch (e) {
    debugPrint('[ConversationProvider] 删除失败: $e');
    _error = '操作失败，请重试';
    notifyListeners();
  }
}
```

**Step 5: 提交**

```bash
git add lib/features/history/providers/conversation_provider.dart
git commit -m "feat(history): add error state + retry to ConversationProvider"
```

---

### Task 5: HistoryPage 错误状态 UI

**Files:**
- Modify: `lib/features/history/history_page.dart`

**需求：** 数据库加载失败时展示错误页 + 重试按钮。

**Step 1: 添加错误状态判断**

在 `history_page.dart` 的 `build()` 中，在 `isLoading` 判断之后：

```dart
if (provider.hasError) {
  return _buildErrorView(provider);
}
```

**Step 2: 实现 `_buildErrorView`**

```dart
Widget _buildErrorView(ConversationProvider provider) {
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.storage_outlined, size: 64, color: AppTheme.textSecondary),
          const SizedBox(height: 16),
          Text(
            provider.error ?? '加载失败',
            style: const TextStyle(fontSize: 16),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () => provider.retry(),
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      ),
    ),
  );
}
```

**Step 3: 提交**

```bash
git add lib/features/history/history_page.dart
git commit -m "feat(history): add error view with retry in HistoryPage"
```

---

### Task 6: 消息发送错误 SnackBar（ConversationProvider 写失败）

**Files:**
- Modify: `lib/features/chat/providers/chat_provider.dart`

**需求：** 对话保存到数据库失败时通知用户。

**Step 1: 在 ChatProvider 的 saveMessages 和 finishConversation 回调中添加 try-catch**

检查 `chat_provider.dart` 中调用 `ConversationRepository` 的地方，加 try-catch 并在失败时设置 `_error`：

```dart
// saveMessages 回调中
try {
  await _conversationRepo?.updateMessages(_currentConversationId!, messages);
} catch (e) {
  debugPrint('[ChatProvider] 保存消息失败: $e');
  _error = '对话保存失败，但对话可以继续';
  notifyListeners();
}
```

**Step 2: ChatPage 的 _onError listener 自动展示 SnackBar**

Task 3 中已添加 error listener，此处自动复用。

**Step 3: 提交**

```bash
git add lib/features/chat/providers/chat_provider.dart
git commit -m "feat(chat): add save-to-db error notification"
```

---

### Task 7: 边界 case — 空话题校验

**Files:**
- Modify: `lib/features/topics/topic_selection_page.dart`

**需求：** 自定义话题输入框不允许空字符串或纯空格。

**Step 1: 添加校验逻辑**

在自定义话题的发送/跳转处（查找 `_onCustomTopicSubmitted` 或类似的 Navigator.push 调用）：

```dart
void _submitCustomTopic(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('请输入话题内容'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return;
  }
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => ChatPage(topic: trimmed),
    ),
  );
}
```

**Step 2: 确认 TopicSelectionPage 中自定义话题的交互实现**

需要先查看 `topic_selection_page.dart` 中自定义话题的实际实现（是 TextField + 按钮还是点击弹出对话框等），确保校验逻辑正确地插入到跳转之前。

**Step 3: 提交**

```bash
git add lib/features/topics/topic_selection_page.dart
git commit -m "feat(topics): validate non-empty custom topic"
```

---

### Task 8: 边界 case — 超长回答限制

**Files:**
- Modify: `lib/features/chat/widgets/chat_input.dart`
- Modify: `lib/features/chat/chat_page.dart`

**需求：** 用户回答限制 3000 字符，防止超长输入导致 Context 溢出和推理性能下降。

**Step 1: chat_input.dart 添加 maxLength**

```dart
// TextField 中添加
maxLength: 3000,
maxLines: null,  // 允许换行
buildCounter: (context, {required currentLength, required isFocused, maxLength}) {
  if (currentLength > 2500) {
    return Text(
      '$currentLength/$maxLength',
      style: TextStyle(color: AppTheme.warning, fontSize: 12),
    );
  }
  return null;
},
```

**Step 2: ChatPage 发送前二次校验**

```dart
void _sendMessage() {
  final text = _controller.text.trim();
  if (text.isEmpty) return;
  if (text.length > 3000) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('回答过长（${text.length}/3000），请精简后发送'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return;
  }
  // ... 现有发送逻辑
}
```

**Step 3: 提交**

```bash
git add lib/features/chat/widgets/chat_input.dart lib/features/chat/chat_page.dart
git commit -m "feat(chat): add 3000 char limit for user input"
```

---

### Task 9: Android 验证 — 项目构建

**Files:**
- Modify: 可能无需修改，先验证

**需求：** 在 Android 模拟器上跑通项目，记录和修复任何问题。

**Step 1: 检查 Android 构建配置**

```bash
cd /Users/superjie-mac/projects/socratic-ai
flutter doctor --android-licenses
flutter build apk --debug 2>&1 | head -100
```

**Step 2: 记录构建结果**

如果构建失败，分析错误原因。可能的坑：
- `llama_cpp_dart` Android 依赖不足（需要 NDK 或 .so 文件）
- Gradle 版本冲突
- 缺少 Android SDK 组件

**Step 3: 修复并重新构建**

根据 Step 2 的错误逐一修复，直到 `flutter build apk --debug` 成功。

**Step 4: 在模拟器上运行**

```bash
flutter run -d <android-emulator-id>
```

验证所有页面交互正常、模型加载不崩溃。

**Step 5: 提交修复**

```bash
git add <modified-files>
git commit -m "fix(android): fix build/runtime issues found in verification"
```

---

### Task 10: 补充测试

**Files:**
- Create: `test/features/chat/chat_page_error_test.dart`
- Create: `test/features/history/history_page_error_test.dart`
- Create: `test/features/topics/topic_selection_validation_test.dart`

**Step 1: ChatPage 模型加载错误 UI 测试**

```dart
// test/features/chat/chat_page_error_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:socratic_ai/features/chat/providers/chat_provider.dart';

void main() {
  testWidgets('shows error view when model loading fails', (tester) async {
    // pump ChatPage with a ChatProvider that has _modelError set
    // verify error icon + retry button + back button are visible
  });

  testWidgets('retry button triggers retryLoadModel', (tester) async {
    // tap retry button, verify ChatProvider.retryLoadModel called
  });

  testWidgets('back button pops navigator', (tester) async {
    // tap back button, verify Navigator.pop called
  });
}
```

**Step 2: HistoryPage 错误状态测试**

```dart
// test/features/history/history_page_error_test.dart
testWidgets('shows error view when db fails', (tester) async {
  // pump HistoryPage with a ConversationProvider that has _error
  // verify error text + retry button visible
});
```

**Step 3: 空话题校验测试**

```dart
// test/features/topics/topic_selection_validation_test.dart
testWidgets('shows snackbar on empty custom topic', (tester) async {
  // enter empty text in custom topic field, submit
  // verify SnackBar '请输入话题内容' appears
});
```

**Step 4: 运行测试确认通过**

```bash
cd /Users/superjie-mac/projects/socratic-ai && flutter test test/features/chat/chat_page_error_test.dart test/features/history/history_page_error_test.dart test/features/topics/topic_selection_validation_test.dart
```

**Step 5: 提交**

```bash
git add test/features/chat/chat_page_error_test.dart test/features/history/history_page_error_test.dart test/features/topics/topic_selection_validation_test.dart
git commit -m "test: add error state and validation tests for Day 7"
```

---

### Task 11: 全量回归测试 + 分析

**Step 1: 运行全部测试**

```bash
cd /Users/superjie-mac/projects/socratic-ai && flutter test
```

**Step 2: 运行静态分析**

```bash
cd /Users/superjie-mac/projects/socratic-ai && flutter analyze lib/
```

目标：0 error，0 warning（1 个已有的 info 可以接受）。

**Step 3: 提交（如有修复）**

```bash
git add <modified-files>
git commit -m "chore: fix analysis warnings and test failures"
```

---

## 执行顺序依赖

```
Task 1 (ChatProvider error state)
  └─→ Task 2 (ChatPage error UI) ──→ Task 3 (inference SnackBar)
                                            ↓
Task 4 (ConversationProvider error)     Task 6 (save error notification)
  └─→ Task 5 (HistoryPage error UI)

Task 7 (empty topic validation) —— 独立

Task 8 (char limit) —— 独立

Task 9 (Android verification) —— 依赖 Task 1-8 完成（确保功能完整后再验证）

Task 10 (tests) —— 依赖 Task 1-8 完成

Task 11 (regression) —— 最后
```

可并行执行的两组：
- 组 A: Task 1 → 2 → 3, Task 4 → 5, Task 6
- 组 B: Task 7, Task 8

**建议按 Task 1 → 11 顺序执行**，因为状态字段改动有传染性。

---

## 验收标准

- [ ] 模型加载失败 → ChatPage 展示错误图标 + 说明 + 重试 + 返回按钮
- [ ] 点重试 → 重新加载模型，成功则进入对话
- [ ] AI 推理失败 → SnackBar 提示"当前为兜底回复"
- [ ] 数据库加载失败 → HistoryPage 展示错误 + 重试
- [ ] 数据库写入失败 → SnackBar 提示"对话保存失败"
- [ ] 空话题 → SnackBar "请输入话题内容"
- [ ] 超长回答 → 超出 3000 无法发送，提示截断
- [ ] `flutter analyze` → 0 error 0 warning
- [ ] `flutter test` → 全部通过（含新增测试）
- [ ] Android 构建成功 (`flutter build apk --debug`)
