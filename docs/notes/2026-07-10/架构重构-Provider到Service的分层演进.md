# 架构重构 — 从 Provider 到 Service 的分层演进

## 起因

一个 SnackBar 防抖修复引发了一场完整的架构讨论。

做完 Day 7 的错误覆盖后，我让 WorkBuddy review 代码。Review 发现了 7 个问题（2 个 Critical、3 个 Important、2 个建议）。修完后，我注意到 `ConversationRepository` 和 `ConversationProvider` 放在 `features/history/` 里很奇怪——它们被 chat、insights、mindmap 四个 feature 共同使用，根本不是 history 专属的。

从「感到奇怪」到「理清架构」，大概经历了两小时的讨论和三次迭代。

---

## 一、最初的问题：目录结构不合理

```
修复前：
features/history/
├── engine/conversation_repository.dart   ← 被 4 个 feature 引用
├── providers/conversation_provider.dart  ← 同上
├── widgets/conversation_card.dart
└── history_page.dart
```

`ConversationProvider` 叫 "Provider"，但使用者不只有 HistoryPage——ChatPage 也通过 `context.read<ConversationProvider>()` 直接调用 `startConversation/saveMessages/finishConversation`。

**第一个重构**：移到 `core/` 里，因为是跨 feature 共享的基础设施。

```
第一版：
core/
├── repository/conversation_repository.dart
├── providers/conversation_provider.dart
```

---

## 二、核心讨论：Provider 还是 Service？

移完了，但我问了一个关键问题：「现在叫 Provider 还合理吗？」

### Provider 和 Service 的本质区别

| 维度 | Provider (ChangeNotifier) | Service |
|------|------|------|
| **状态归属** | 自己持有状态，通知别人变化 | 无状态，只是执行操作 |
| **消费方式** | Consumer / context.watch 响应式 | 调用方自行管理状态 |
| **典型职责** | 页面级状态管理，UI 数据流 | 数据访问、外部 API 调用 |
| **生命周期** | 需要 dispose | 无状态，不需要清理 |

`ConversationProvider` 的实际情况：
- ChatPage 用它是**命令式**的（"开始会话"、"保存消息"）——不需要监听状态变化
- HistoryPage 用它是**响应式**的（Consumer 监 listening loading/error/list）——需要状态变化通知
- 它持有 `_activeConversationId`，但这个状态实际上只属于 ChatPage

结论：它的「响应式」职责应该还给各自的 Provider（HistoryProvider 管列表状态，ChatProvider 管会话 id），它自己退化成纯数据访问层。

### 第二版：ConversationProvider → ConversationService

```
第二版：
core/engine/conversation_service.dart   ← 纯 Service，不继承 ChangeNotifier
core/repository/conversation_repository.dart

features/history/   ← HistoryPage 自己用 setState 管理状态
features/chat/      ← ChatPage 直接持有 ConversationService 实例
```

---

## 三、又一个问题：Page 直接调 Service？

第二版跑通了，但看起来还是不对劲——ChatPage 和 HistoryPage 都直接持有 `ConversationService` 实例。

这违反了一个直觉：**Page 层不应该知道数据层怎么工作。**

类比一下：
- ChatPage 不直接调 LlamaService——通过 ChatProvider
- InsightsPage 不直接调 MindMapService——通过 InsightProvider
- 那为什么 ChatPage 和 HistoryPage 直接调 ConversationService？

### 第三版：Provider 作为胶水层

```
第三版（最终）：

ChatPage ──→ ChatProvider ──→ ConversationService ──→ Repository
               (startConversation/saveMessages/finishConversation 全部内聚)

HistoryPage ──→ HistoryProvider ──→ ConversationService ──→ Repository
                 (loadAll/toggleFavorite/deleteConversation)
```

**ChatProvider 的变化**：
- 新增 `_conversationService` 实例和 `_activeConversationId`
- `startConversation()` — 创建持久化记录并存储 id
- `sendMessage()` 的 finally 块自动调用 `_saveMessages()`
- `endConversation()` 内部完成洞察持久化
- ChatPage 完全不知道 ConversationService 的存在

**HistoryProvider 的变化**（新建）：
- 管理 `_conversations` / `_isLoading` / `_error` 状态
- `loadAll` / `toggleFavorite` / `deleteConversation` / `retry`
- HistoryPage 恢复 `Consumer<HistoryProvider>` 模式

---

## 四、最终分层规则

```
Page ──→ Provider ──→ Service ──→ Repository
(UI)     (状态管理)    (数据操作)   (存储)
```

| 层 | 位置 | 约束 |
|:--|------|------|
| Page | `features/<name>/` | 只通过 Consumer 读 Provider；不直接调 Service |
| Provider | `features/<name>/providers/` | 继承 ChangeNotifier；可调 Service |
| Service | `core/engine/` | 不继承 ChangeNotifier；纯数据访问 |
| Repository | `core/repository/` | 数据库/API 调用；不持有 UI 状态 |

**禁止项**（渐进式沉淀）：
- ❌ Page 直接 import engine 或 repository 层
- ❌ Page 直接使用 Service（应通过 feature 专属 Provider）
- ❌ Provider 跨 feature 共享（应放 core/ 或抽 Service）
- ❌ Provider 导入 Page 或 Widget

---

## 五、Code Review 发现的典型问题

这次重构的触发点是 Code Review，Review 本身也暴露了几类值得反思的问题：

### 1. 遗漏的 try-catch

`saveMessages`、`startConversation`、`finishConversation`、`toggleFavorite` 四个写操作缺 try-catch。

**为什么会遗漏？** 因为这几个方法是从 Provider 的 `notifyListeners()` 模式遗留下来的——在 Provider 里，错误可以通过设置 `_error` 字段 + notify 来消费。但切到 Service 后，Service 本身就是被调方，异常会向上抛给 Provider。如果 Provider 不 catch，就 crash。

**教训**：切架构模式时，要检查每一处异常边界是否被正确覆盖。

### 2. ChangeNotifier 死代码

`InsightProvider extends ChangeNotifier`，调了 `notifyListeners()`，但没有任何 Widget 在 `Consumer<InsightProvider>` 里 listen。`_isGenerating` 字段永远读不到，`dispose()` 永远不会被调。

**为什么会写出这种代码？** 习惯性 extend ChangeNotifier 是 Provider 模式的惯性。不是所有叫 "Provider" 的类都需要 reactive——如果调用方只做命令式调用（调一个方法，等它返回），不需要监听状态变化，就不应该 extend ChangeNotifier。

**判断标准**：问自己「有没有 Widget 需要在我状态变化时自动重建？」如果没有 → 不要 extend ChangeNotifier。

### 3. SnackBar 防抖从全局到 keyed

第一版 `SnackBarThrottle` 用单一全局时间戳——500ms 内所有消息互斥。理论上"话题为空"的 SnackBar 会吞掉"图谱生成失败"的 SnackBar。

第二版改为 `Map<String, int>` 按消息文本做 keyed throttle——只有完全相同消息才被抑制。

**教训**：全局状态做限流时，要想清楚限流的粒度。同一类操作（同一个消息文本）应该合并，不同类操作不应该互斥。

---

## 六、这次重构教给我的

### 1. 「感到奇怪」是重构的信号

当你说「这个文件放在这里感觉不太对」，那就是应该动手的信号。不要等。

### 2. 先移位置，再改名字，最后改行为

这次重构的顺序：
1. 先把文件物理移动到 `core/`
2. 再讨论名字（Provider → Service）
3. 再改行为（去掉 ChangeNotifier）
4. 最后补胶水层（加回 HistoryProvider / ChatProvider 内聚）

每一步只做一件事，`flutter analyze` 验证后再走下一步。如果一步到位全改完，大概率会改崩。

### 3. Code Review 比自己检查有效

自己写的代码回头看很难发现问题——因为大脑会自动补全你「以为写了」的代码。Review 子代理会严格对照 Plan 一条一条对，能把遗漏的 try-catch、死代码、测试覆盖缺口全部揪出来。

### 4. 分层规则不是教条，是共识

「Page 不能直接调 Service」这条规则不是一开始就有的——是因为我尝试了让 Page 直接调 Service，发现不对，才沉淀成规则。规则的价值在于：下次再遇到同样场景，不需要重新思考一遍。
