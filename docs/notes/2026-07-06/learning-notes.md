# 2026-07-06 — 学习笔记

> 今天完成了代码审查、Day 3 对话引擎、Day 4 洞察总结、Day 5a 端侧持久化，以及两轮工程架构整顿。
> 以下从语言、架构、业务三个维度沉淀关键学习点。

---

## 一、Dart / Flutter 语言与框架

### 1.1 ChangeNotifierProvider 的 create 与 read 时序陷阱

**问题**：在 `initState` 中用 `addPostFrameCallback` 去 `context.read<ChatProvider>()`，报 `ProviderNotFoundException`。

```dart
// ❌ 错误——Provider 还没被创建（它在 build() 的 ChangeNotifierProvider 里）
@override
void initState() {
  super.initState();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    context.read<ChatProvider>().loadModel();  // ProviderNotFound!
  });
}
```

**原因**：`ChangeNotifierProvider.create` 在 `build()` 方法中执行。`initState` 先于 `build()`，即使 `addPostFrameCallback` 延迟到当前帧绘制后，`context` 指向的 widget 树里还没有 Provider。

**正确做法**：在 `create` 回调内部调用 fire-and-forget 异步方法：

```dart
// ✅ 正确——Provider 刚创建，立即触发模型加载
return ChangeNotifierProvider(
  create: (ctx) {
    final provider = ChatProvider(topic: topic);
    provider.loadModel();  // fire-and-forget，不阻塞 return
    return provider;
  },
);
```

`loadModel()` 内部 `setState`（实际是 `notifyListeners`）会触发 UI 重建，加载状态通过 `isModelLoading` getter 暴露。

### 1.2 `late final` 解决闭包中的自引用问题

**问题**：ChatProvider 的 `onMessagesChanged` 回调需要引用 `provider.messages`，但 `provider` 变量在赋值右侧的闭包内还没初始化完。

```dart
// ❌ 编译错误：provider 在闭包内引用自己时尚未声明
create: (_) {
  final provider = ChatProvider(
    onMessagesChanged: () {
      repository.saveMessages(provider.messages);  // referenced_before_declaration
    },
  );
  return provider;
},
```

**解**：`late final` 允许"先声明后赋值"，闭包捕获的是变量引用而非值：

```dart
// ✅ 编译通过——late 允许声明与赋值分离
create: (_) {
  late final ChatProvider provider;
  provider = ChatProvider(
    onMessagesChanged: () {
      repository.saveMessages(provider.messages);  // 闭包捕获 provider 引用
    },
  );
  return provider;
},
```

**原理**：Dart 的闭包捕获变量本身（不是值拷贝）。`late final` 声明了变量，闭包拿到引用，赋值后闭包访问到的是赋值后的值。这是 Dart 区别于 Java（effectively final）的重要特性。

### 1.3 `ChangeNotifier.dispose` 的继承链

当 Provider 管理了需要手动释放的资源（如 llm engine），必须在 `dispose` 中清理：

```dart
class ChatProvider extends ChangeNotifier {
  DialogueEngine? _engine;

  @override
  void dispose() {
    // 先释放子资源
    if (_engine is SocraticPrompter) {
      (_engine as SocraticPrompter).dispose();
    }
    // 再调用父类 dispose
    super.dispose();
  }
}
```

Flutter 的 `ChangeNotifierProvider` 在 widget 从树中移除时自动调用 `dispose`，但前提是你覆盖了它。

### 1.4 Dart 的 type promotion 与 unnecessary_cast

Dart 在 `is` 检查后会自动提升类型，手动 cast 反而会触发 lint 警告：

```dart
// ❌ unnecessary_cast warning
if (engine is! SocraticPrompter) return;
final service = InsightService((engine as SocraticPrompter).llmService);

// ✅ type promotion 自动生效
if (engine is! SocraticPrompter) return;
final service = InsightService(engine.llmService);  // engine 已被提升
```

### 1.5 sqflite 单例模式

`ConversationRepository` 采用静态单例——数据库只需初始化一次：

```dart
class ConversationRepository {
  static Database? _db;

  static Future<void> initialize() async {
    _db = await openDatabase(
      path.join(await getDatabasesPath(), 'socratic.db'),
      version: 1,
      onCreate: (db, version) async {
        await db.execute('CREATE TABLE conversations (...)');
      },
    );
  }

  Database get _ensureDb {
    if (_db == null) throw StateError('ConversationRepository 未初始化');
    return _db!;
  }
}
```

**注意**：`getDatabasesPath()` 在 `WidgetsFlutterBinding.ensureInitialized()` 之后才能调用，所以 `main()` 必须是 `Future<void> main() async`。

### 1.6 JSON 列存储策略

messages 和 insight 以 JSON TEXT 列存储，不做独立表：

```dart
// 写入
'messages_json': jsonEncode(messages.map((m) => {
  'role': m.role.name,    // enum → string
  'content': m.content,
  'round': m.round,
}).toList())

// 读取
static List<ChatMessage> _parseMessages(String? json) {
  if (json == null || json.isEmpty) return [];
  final list = jsonDecode(json) as List;
  return list.map((e) => ChatMessage(
    role: MessageRole.values.firstWhere((r) => r.name == e['role']),  // string → enum
    content: e['content'],
    round: e['round'],
  )).toList();
}
```

**取舍**：无消息检索需求 → JSON 整批覆盖比逐条 INSERT 简单且性能更好（10 轮对话约 3-5KB）。

---

## 二、工程架构

### 2.1 分层违规的本质原因

今天做了两轮架构审查，发现的共同模式：**Page 层"太能干"**.

| 违规 | 原位置 | 根本原因 |
|:--|:--|------|
| ChatPage import LlamaService/SocraticPrompter/InsightService | `chat_page.dart` | Page 自己加载模型、自己生成洞察 |
| ChatPage import ConversationRepository | `chat_page.dart` | Page 直接写数据库 |

修复策略一致：**把逻辑提升到 Provider 层**。

```dart
// ❌ Page 做引擎初始化（违反分层）
class _ChatPageState {
  Future<void> _initEngine() async {
    final llm = LlamaService();
    await llm.loadModel(...);       // Page 直接调 engine
    final engine = SocraticPrompter(llm);
    await engine.initialize();      // Page 直接调 engine
    _engine = engine;
  }
}

// ✅ Provider 封装引擎初始化
class ChatProvider {
  Future<void> loadModel() async {
    _isModelLoading = true;
    notifyListeners();              // UI 通过 getter 感知状态
    final llm = LlamaService();
    await llm.loadModel(...);
    final engine = SocraticPrompter(llm);
    await engine.initialize();
    _engine = engine;
    _isModelLoading = false;
    notifyListeners();
  }
}
```

### 2.2 最终分层规范

```
pages/widgets  ──→  providers  ──→  engine / repository  ──→  models / core
     ↑                ↑                   ↑
  只看到        可以调 engine         只看到 model
  Provider      和 repository         和 core 工具
```

**判断违规的简单规则**：看 import 语句。如果 page 文件 import 了 `engine/` 或 `repository/` 路径下的文件，100% 是违规。

### 2.3 Provider 的生命周期管理

`ConversationProvider` 的设计体现了 Provider 的双重职责：

```dart
class ConversationProvider extends ChangeNotifier {
  // 职责 1：活跃会话生命周期（ChatPage 调用）
  Future<int> startConversation(String topic) { ... }
  Future<void> saveMessages(List<ChatMessage> messages) { ... }
  Future<void> finishConversation(InsightResult? insight) { ... }

  // 职责 2：历史列表管理（HistoryPage 调用）
  Future<void> loadAll() { ... }
  Future<void> toggleFavorite(int id) { ... }
  Future<void> deleteConversation(int id) { ... }
}
```

**一个 Provider 管理一个数据域**，不搞"一个表一个 Provider"的过度拆分。

### 2.4 跨 Provider 通信用回调注入

ChatProvider 需要通知 ConversationProvider 保存消息，但不是通过 Provider 嵌套（容易产生时序问题），而是通过回调：

```dart
// ChatPage 作为协调者
ChangeNotifierProvider(
  create: (ctx) {
    final convProvider = ctx.read<ConversationProvider>();
    return ChatProvider(
      onMessagesChanged: () {
        convProvider.saveMessages(provider.messages);
      },
    );
  },
);
```

**模式**：Page 层负责 Provider 之间的协调（"胶水代码"），Provider 之间不互相调用。这比 Provider 之间直接依赖更清晰——每个 Provider 保持独立，换一个 Provider 实现时不需要改动另一个。

### 2.5 UI 交互的分支处理：`fromHistory` 参数

同一个页面（InsightsPage）有两种进入方式，交互行为不同：

| | 从对话流程进入 | 从历史列表进入 |
|:--|:--|:--|
| AppBar | 右上方「完成」 | 左上方返回箭头 |
| 「开始新对话」 | 清空栈→push 首页 | pop 返回历史列表 |

**设计选择**：用 `bool fromHistory` 参数而非回调 `VoidCallback? onNewConversation`。后者更灵活但过度设计——这里只有两种行为，布尔值够用且调用方不需要知道具体跳转逻辑。

---

## 三、苏格拉底 AI 业务

### 3.1 梯度追问策略的设计哲学

从 v5（固定 5 维度轮换）升级到 v6（梯度 ProbeStage），核心理念是**追问深度随对话自然增长**：

```
探索期（轮次 1）   → "你提到的XX具体指什么？"        # 收集信息
深入期（轮次 2-3） → "你认为这个选择背后代表什么价值观？" # 挖掘假设
挑战期（轮次 4-6） → "你之前说XX，现在说YY，这中间的变化是什么？" # 暴露矛盾
总结期（轮次 7+）  → "回顾整段对话，你最大的收获是什么？" # 引导自省
```

每个阶段通过 Dart 侧的追问方向 hint 注入 Prompt，LLM 在 hint 约束下生成具体追问，而不是让 LLM 自由发挥。这解决了一个核心问题：小模型（2B）本身不具备"苏格拉底式追问"的能力，但加上梯度策略后可以模拟出类似效果。

### 3.2 洞察总结的 JSON 容错三层回退

小模型输出 JSON 不稳定，所以 InsightService 用了三层容错：

```
第 1 层：jsonDecode(raw)                                 → 成功则直接返回
第 2 层：提取 ```json ... ``` 代码块再解码                → 处理模型"多说话"的情况
第 3 层：正则匹配 {"core_insights": [...]} 片段           → 只拿需要的部分
兜底层：原始文本作为单条 coreInsight 展示                 → 保证用户至少能看到东西
```

**设计取舍**：容错性 > 精确性。小模型阶段宁可展示不完整的洞察，也不让用户看到空白页或报错。

### 3.3 对话历史持久化的写入时机

三条规则，按优先级：

1. **进入 ChatPage** → `INSERT` 创建记录（status='active'）
2. **每轮 AI 回复完成后** → 整批 JSON 覆盖 `messages_json`
3. **结束对话** → 写入 `insight_json` + `status='completed'`

**选择整批覆盖而非逐条 INSERT 的原因**：无消息检索需求，10 轮对话 JSON 约 3-5KB，避免了每轮都开数据库事务。

**最坏情况**：用户退出时最多丢失当前未完成的最后一轮 AI 回复。下一轮完成时会自动覆盖保存。

### 3.4 Token 管理策略

```
静态估算 = 英文字符 × 0.25 + 中文字符 × 1.5（BPE 平均）
累计追踪 = seedContext 时 + 每轮 generateResponse 时
警告阈值 = > 1800 tokens（nCtx=2048，预留 10% 余量）
截断策略 = llama.cpp KV cache 自动截断（Dart 层只监控不干预）
```

**为什么不在 Dart 层手动截断**：llama.cpp 的 KV cache 截断比手动删除消息更可靠——它保留最新的 token 而非粗暴删除旧消息，语义连贯性更好。

---

## 四、踩坑记

| 坑 | 现象 | 根因 | 修复 |
|:--|------|------|------|
| ProviderNotFound | 启动 crash | initState 中用 addPostFrameCallback 读尚未创建的 Provider | loadModel 移到 create 回调 |
| referenced_before_declaration | 编译失败 | 闭包引用未声明变量 | `late final` 分离声明与赋值 |
| 模型路径找不到 | LLM 不工作 | debug build 可执行文件路径与项目根不对应 | dev 阶段用绝对路径常量 |
| unnecessary_cast | lint warning | is 检查后 Dart 已提升类型 | 删除多余的 `as` cast |
| 历史页 push 动画 | 返回行为不符合预期 | InsightsPage 不分来源统一用 pushAndRemoveUntil | 新增 fromHistory 参数 |

---

## 五、今天新增的文件清单（供复习）

```
lib/core/models/conversation.dart          # 持久化模型（toMap/fromMap/copyWith）
lib/core/engine/llama_service.dart          # +engine getter +repeatPenalty +estimateTokens
lib/features/chat/engine/socratic_prompter.dart  # 梯度策略重写 + Token 追踪
lib/features/chat/providers/chat_provider.dart   # +loadModel +endConversation +isModelReady
lib/features/chat/chat_page.dart            # 精简为纯 UI + Provider 协调
lib/features/insights/engine/insight_service.dart  # 洞察提取 Prompt + JSON 三层回退
lib/features/insights/insights_page.dart    # +fromHistory 分支交互
lib/features/insights/widgets/*             # 4 个 widget 独立文件
lib/features/history/engine/conversation_repository.dart  # sqflite CRUD 单例
lib/features/history/providers/conversation_provider.dart # 活跃会话 + 历史列表
lib/features/history/widgets/conversation_card.dart       # 历史卡片
lib/features/history/history_page.dart      # 完整列表 + 空状态
lib/main.dart                               # async init DB + Provider 注入
test/core/models/conversation_test.dart     # 序列化往返测试（6 用例）
docs/plans/2026-07-06-day5a-local-persistence.md  # 实现计划
```
