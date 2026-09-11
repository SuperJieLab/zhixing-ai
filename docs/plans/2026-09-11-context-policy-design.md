# 知行AI — 对话上下文管理抽象（ContextPolicy）

> 状态：设计已确认（2026-09-11 对话确认。用户拍板：① ContextPolicy 抽象成立；② **能力对等**——双端都要有压缩/摘要能力与基本实现，"碰到不归碰到，设计上得有"；③ 云端摘要用云端模型做（质量更好）；④ 时机排在 BYOK 真机冒烟之后）
> 前置：`2026-09-09-context-compaction-design.md`（本地滚动摘要，已落地）、`2026-09-10-byok-cloud-design.md`（云端直连）

## 1. 背景与问题

上下文管理逻辑目前**写死在两个 ChatClient 内部**，已经出现职责错位与重复：

| 概念 | 本地（LocalChatClient） | 云端（CloudChatClient） | 问题 |
|---|---|---|---|
| 欢迎语过滤（round==0） | 隐式（diff append 全量） | `where((m) => m.round != 0)` | **同一逻辑两处实现** |
| 上下文装配 | 预算驱动装窗（`localInputBudget`） | 固定尾部 `_windowSize = 10` 条 | 同一职责、两套代码 |
| 压缩/摘要 | 有（Summarizer + 递归摘要卡 + 溢出强制压缩） | 无 | 能力缺失 |
| 溢出自愈 | 有（`LlamaDecodeException` → 强制 compact） | 无 | 端侧特有 |

两个判断：

1. **这是职责错位**：上下文装配是「对话领域逻辑」，与「传输/推理后端」正交，却塞进了传输层。`round==0` 写两遍即为信号。
2. **云端的「取尾 10 条」是本地方案的退化特例**：尾部优先装窗 + 可摘要的算法是通用算法，云端只是「预算极小（10 条）+ 摘要器关闭」。因此「能力一致、策略不同」无需发明新东西，只需把已有算法**参数化**并让双端共用。

## 2. 已确认决策

| 决策点 | 结论 |
|---|---|
| **抽象形态** | 新增 `ContextPolicy` 承载「对话历史 → 实际发送的消息」职责，双端各一份策略实现 |
| **能力对等** | 双端**都必须**具备过滤 / 度量 / 装窗 / 压缩四项能力与基本实现；差异只允许落在「度量单位」与「摘要器实现」两个策略位 |
| **云端摘要器** | 用云端模型实现（复用同一个 BYOK 端点，**非流式**小请求），质量优于端侧 2B；预算设得远大于装窗需求，实践中基本不触发，但机制完整可测 |
| **抽象边界** | 接口签名禁止出现端侧专属概念（`nCtx`/`LlamaDecodeException`/`llama*`）；自愈以中性钩子 `handleOverflow()` 暴露 |
| **人设归属** | 不动既有决策：「人设唯一出处 = `ConversationStrategy.buildSystemPrompt`」（提交 020c27a），Policy 只管历史与摘要卡 |
| **实施时机** | 排在 BYOK 真机冒烟之后；本轮重构覆盖两个 client 的装配路径，不与未验证变更混提 |

## 3. 能力拆解（五个正交能力）

| # | 能力 | 职责 | 双端关系 |
|---|---|---|---|
| ① | 过滤 Filtering | 哪些消息有资格进上下文（round==0 欢迎语等） | **共享实现** |
| ② | 度量 Estimation | 一段消息占多少预算 | 策略位（单位不同） |
| ③ | 装窗 Packing | 预算内怎么装（尾部优先、保底最近消息） | **共享实现** |
| ④ | 压缩 Compaction | 装不下的移出消息如何压缩（摘要卡） | 策略位（摘要器不同） |
| ⑤ | 溢出自愈（钩子） | 传输层报告溢出 → 强制收缩 | **共享契约**（触发侧端侧特有） |

要点：**双端差异全部落在②④，①③⑤为双端同一段代码**。①③⑤的重复/缺失随本次抽取一并消除。

## 4. 接口设计

```dart
/// 装配结果：要发送的历史 + 可选的摘要卡（client 以 system 消息注入）。
class AssembledContext {
  final List<ChatMessage> messages; // 已过滤 + 装窗后的历史
  final String? summaryCard;        // 此前对话摘要卡（含前缀，滚动更新，可为 null）
}

/// 上下文策略：对话历史 → 实际发送的消息
abstract class ContextPolicy {
  /// 装配本次请求上下文。超预算时内部执行压缩（可能触发摘要器）。
  /// [systemPrompt] 仅参与预算核算（人设与摘要卡占用同一预算），不由本策略注入。
  Future<AssembledContext> assemble(List<ChatMessage> history,
      {String systemPrompt = ''});

  /// 传输层溢出钩子（如本地 context full）：强制收缩，下次装配生效。
  Future<void> handleOverflow();
}

/// 度量能力（策略位②）
abstract class ContextEstimator {
  int estimateMessage(ChatMessage message); // 单条（含该后端的模板开销）
  int estimateText(String text);            // system 提示词 / 摘要卡
  int estimateMessages(List<ChatMessage> messages); // 默认逐条累加
}

/// 摘要能力（策略位④）：移出消息 + 旧摘要 → 新摘要卡
abstract class ConversationSummarizer {
  Future<String> summarize(
      String previousSummary, List<ChatMessage> evicted);
}
```

**共享实现**（① 过滤 / ③ 装窗 / 「①③⑤同一段代码」的落点）：

```dart
List<ChatMessage> filterEligible(List<ChatMessage> history); // 剔 round==0

class PackResult { List<ChatMessage> kept, evicted; int used; }

PackResult packTailWithinBudget(List<ChatMessage> eligible,
    {int budget, ContextEstimator estimator, int baseCost, int minKeep});
PackResult packKeepLast(List<ChatMessage> eligible,
    {int keep, ContextEstimator estimator, int baseCost}); // 溢出自愈硬收缩

/// 双端共用的装配编排：过滤 → 装窗 → 必要时摘要（含"已摘要游标"防重复摘要）
abstract class BaseContextPolicy implements ContextPolicy {
  BaseContextPolicy({required ContextEstimator estimator, required int budget,
      ConversationSummarizer? summarizer, int minKeep = 2, int? overflowKeep});
}
```

**双端策略 = 对 `BaseContextPolicy` 的参数装配**（Task 2/3 落地为薄子类/工厂）：编排逻辑不重复实现，差异全部落在构造参数——这正是「能力一致、策略不同」的直接体现。

设计约束：

- `assemble` 为 `Future`（压缩可能触发异步摘要）。
- 摘要卡以独立字段返回而非伪装成 `ChatMessage`——`ChatMessage` 无 system 角色，不为此扩展模型；由 client 决定注入位置。
- `handleOverflow()` 无返回值：由 client 决定本轮降级文案与下轮重试（保持与现状一致）。
- **已摘要游标**：`BaseContextPolicy` 记录「eligible 前缀中已折叠进摘要的长度」，历史增长时只对新移出的消息再摘要，避免重复摘要同一批内容（等价于现本地 `_mirror` 被压缩后只剩 kept 的效果）。

## 5. 双端策略实现

```dart
// 双端策略均为 BaseContextPolicy 的薄装配（编排共享，只注入差异位）
class LocalContextPolicy extends BaseContextPolicy {
  LocalContextPolicy({required LlamaEngine engine, Summarizer? summarizer})
      : super(
          estimator:  LlamaTemplateEstimator(),      // 模板规则精确估算（LlamaService.estimateTokens + 每条 +16 overhead）
          budget:     AppConstants.localInputBudget, // 1668（nCtx 4096 − maxTokens 2048 − margin 384）
          summarizer: summarizer == null ? null : LlamaSummarizer(summarizer),
          minKeep:    2,                             // 最后 2 条保底（当前问题原文必须可见）
          overflowKeep: 4,                           // context full 自愈：硬留最后 4 条
        );
}

class CloudContextPolicy extends BaseContextPolicy {
  CloudContextPolicy({required baseUrl, apiKey, modelName})
      : super(
          estimator:  HeuristicEstimator(),          // 字符数近似（粗粒度，诚实不装精确）
          budget:     <待定，量级 10 万字符>,          // 远大于装窗需求 → 基本不触发
          summarizer: CloudSummarizer(baseUrl, apiKey, modelName), // 同一 BYOK 端点，非流式小请求
          minKeep:    2,
          overflowKeep: null,                        // 契约对称，不收缩
        );
}
```

云端摘要器实现要点：`POST {baseUrl}/chat/completions`，`stream: false`，`max_tokens` 取小值（如 512），prompt 复用 `ConversationStrategy.buildSummaryPrompt`，返回内容同样经 `stripThinkTags` 清理；异常向上抛由 policy 兜底回落（纯窗口丢弃）。

## 6. 边界与红线

| 事项 | 归属 | 理由 |
|---|---|---|
| 人设 system prompt | `ConversationStrategy`（不动） | 人设唯一出处，双端逐字一致（020c27a） |
| `LlamaDecodeException` 捕获与重试 | `LocalChatClient` | 传输层错误属传输层；client 捕获后调 `policy.handleOverflow()` |
| SSE 解析、超时、取消 | 各自 client | 传输细节，与上下文策略无关 |
| 摘要卡注入位置 | client 装配时 | policy 只产出内容，默认排在 persona 之后 |
| 会话态（摘要卡、累计估算） | policy 实例（与对话同生命周期） | 由 provider 随 client 一起创建（`ChatPage` providerFactory 注入缝现成） |

**防泄漏红线**：`ContextPolicy` / `ContextEstimator` / `ConversationSummarizer` 的签名与实现文件中不得出现 `nCtx`、`llama`、`EngineChat` 等端侧概念；端侧细节封装在 `LocalContextPolicy` 及其注入实现内。

## 7. 迁移路径

```
现状：LocalChatClient(内嵌 compact/摘要)   CloudChatClient(内嵌 tail-10 窗口)
目标：LocalChatClient ──▶ LocalContextPolicy ─┐
      CloudChatClient ──▶ CloudContextPolicy ─┴─▶ 共享：过滤 + 装窗 + Overflow 契约
```

1. 抽取共享层（接口 + 过滤 + 装窗算法 + **装配骨架 `BaseContextPolicy`** + 单测）——不接 client，零行为变更。
2. `LocalContextPolicy`：把 `LocalChatClient` 现有 `_compactContext` / `_mirror` / `_summary` / `_estimatedTokens` 迁移进来，client 改为委托；现有测试语义保留（fake session/summarizer 注入路径改为 policy 注入）。
3. `CloudContextPolicy`：替换 `_windowSize = 10` 硬编码；接入 `CloudSummarizer`。
4. 收尾：全量回归 + 文档 + 冒烟项。

## 8. 测试策略

| 对象 | 方式 |
|---|---|
| 共享装窗算法 | 纯单测：预算装窗（长消息少留 / 短消息多留）、minKeep 保底、预算充足全量透传 |
| 共享过滤 | 纯单测：round==0 剔除（双端复用同一用例表） |
| LocalContextPolicy | fake estimator/summarizer：触发阈值、摘要递归压实（旧摘要 + evicted 入参）、摘要失败回落纯丢弃、`handleOverflow` 强制收缩且内容真减 |
| CloudContextPolicy | fake estimator/summarizer：预算内透传、超预算压缩路径（构造小预算强制触发）、`handleOverflow` 无害 |
| CloudSummarizer | mock Dio/HTTP：请求体（非流式、model、max_tokens）、响应解析、think 剥离、非 2xx 抛错 |
| 回归 | 双端 client 既有测试全绿（`ChatClient` 接口不变，provider 侧零改动） |

## 9. 风险

- **抽象泄漏**：策略位设计不当会把端侧概念带进共享层——以 §6 红线与 code review 守住。
- **云端摘要器成本**：用用户自己的 key 发摘要请求；以「预算极大 + 基本不触发」+ 文档说明控制（触发时是几百 token 的一笔小请求）。
- **改造面覆盖两个 client**：属本次唯一高风险点，故**排在 BYOK 冒烟之后**，且 Task 1 保持零行为变更，逐 Task 可提交、可回退。
- **既有语义回归**：diff 增量 append、`_skipNextHistoryAi`、去重改写、think 剥离均不属本抽象职责，必须原样保留。

## 10. 范围外（明确不做）

- 异步预压缩（回复结束后台生成摘要）——仍为后续候选
- 摘要随 Conversation 持久化 / 跨启动恢复
- 本地 KV cache 平移（插件路径不可用，见 2026-09-09 压缩设计 §1）
- `ConversationStrategy` 人设与 goals 注入链路调整
- 服务端任何改动（BYOK 后服务端不参与对话链路）
