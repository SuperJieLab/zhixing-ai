# 知行AI — 本地对话上下文压缩（滚动摘要）

> 状态：设计已确认（2026-09-09 对话确认，两个决策点用户已拍板：方案 A 滚动摘要；压缩触发不固定保留条数、按预算即时压缩）
> 背景：真机日志 `LlamaDecodeException: context full at pos=4095 / nCtx=4096`，本地多轮后持续失败

## 1. 背景与根因

本地会话上下文 4096 填满后，`generateResponse` 的 decode 从第一 token 就失败，且后续每轮持续失败（估算值够不到截断阈值，永不自愈）。三层叠加：

| # | 根因 | 位置 |
|---|---|---|
| 1 | 截断阈值 = 75% × 4096 ≈ 3072，但生成还预留 `maxTokens = 2048`，最坏 3072+2048 = 5120 > 4096，预留不足 | `local_chat_client.dart:102-103` |
| 2 | `estimateTokens` 纯文本启发式，漏算每条消息 chat template 包装开销与 `<think>` 思考 token（占据 session 上下文但被剥离后不进 mirror/估算），真实 n_past 系统性跑在估算前面 | `LlamaService.estimateTokens` |
| 3 | context full 后无自愈：截断只在 `_estimatedTokens > 3072` 时触发，估算偏低则永远够不到，会话永久卡死 | `local_chat_client.dart:167` |

报错文案建议的 `Request.shiftPolicy = ContextShiftPolicy.auto` **对本项目不可用（2026-09-09 实施时核查修正）**：插件的 `EngineSession.generate`/`LlamaSession.generate` 确实暴露 `shiftPolicy`（auto = llama-server 式 KV 平移，需 `engine.canShift`），但 `EngineChat`（chat-template 路径，本项目唯一使用入口）未透传——worker 端 `_runGenerateChat` 调 `_streamSessionGenerate` 时用默认 `off`。启用平移需放弃 EngineChat 自行渲染模板，且平移是静默丢旧上下文，语义劣于滚动摘要。故恢复手段维持重建 session（现有 `_truncateContext` 即此，只是没被触发到）。

另核查确认：插件 worker 每次 generate 前 `session.clear()` + 全量渲染 prompt 重新 prefill——因此 context full 发生在**整段渲染 prompt** 上，重建 session 若内容不减（同 mirror）则同样的 prompt 依旧撑爆，自愈必须**真正减少内容**（见 §3.4）。

## 2. 已确认的决策

| 决策点 | 结论 |
|---|---|
| **压缩方案** | A. 滚动摘要（rolling summary）：被移出的旧对话用本地模型压成摘要卡，随系统提示词进新 session。B（结构化目标卡）不选——strategy_brief 管线已承载该职责，goals 已注入系统提示词；C 混合不做 |
| **触发与保留窗口** | 预算驱动即时压缩：**不固定保留 12 条**。估算超阈值才压缩（平时零开销）；保留窗口从尾部往前装，能塞进预算的最近消息全部保留原文，装不下的进摘要。窗口大小是结果不是配置 |
| **摘要递归压实** | 已有摘要 + 本轮移出消息 → 合并生成新摘要，摘要长度有上限，不随对话无限增长 |
| **压缩时机** | v1 同步：触发轮回复前先做摘要（用户等待几秒可接受）。异步预压缩（回复结束后）列为后续优化 |
| **摘要持久化** | v1 仅内存（app 内恢复会话重新累积）；是否随 Conversation 落库单独决策，不在本迭代 |
| **前置修复** | 阈值修正 + context-full 自愈（§4 Task 1）先行——压缩解决「截断丢信息」，不解决「估算偏低撑爆」；两者覆盖不同故障面 |

## 3. 压缩机制设计

### 3.1 参数（Task 1 修正后）

```dart
_maxTokens = 2048;                                    // 生成预留（既有）
_contextMargin = 384;                                 // template 开销 + 估算误差余量
// 截断/压缩阈值：nCtx − maxTokens − margin ≈ 1668（约 40%）
_threshold = AppConstants.modelContextSize - _maxTokens - _contextMargin;
_perMessageOverhead = 16;                             // 每条消息 template 开销，append 时累加
```

`LocalChatClient` 的 `truncateThreshold` 测试注入参数保留，仅默认值算法变更。

### 3.2 compact 算法（替换 `_truncateContext`）

```
compact():
  budget = _threshold                                  // 新 session 总估算上限
  base = estimate(systemPrompt) + estimate(摘要卡)
  // 从尾部往前装，保留能放下的最近消息（至少保留最后 2 条，
  // 保证当前问题原文可见——它已 append 进旧 session，不能只存在于摘要里）
  kept = []; used = base
  for msg in _mirror.reversed:
    t = estimate(msg) + overhead
    if used + t > budget && kept.length >= 2: break
    kept.prepend(msg); used += t
  dropped = _mirror - kept
  if dropped 非空:
    newSummary = summarizer(_summary, dropped)          // 失败 → 回落：丢弃 dropped 不生成摘要
    _summary = newSummary（≤ 200 字）
  重建 session: addSystem(systemPrompt)
               if _summary: addSystem('【此前对话摘要】\n_summary')
               for msg in kept: append
  _estimatedTokens = used（含摘要卡）
```

### 3.3 摘要生成器（Summarizer）

- 抽象：`typedef Summarizer = Future<String> Function(String previousSummary, List<({String role, String content})> dropped);`（测试注入 fake）
- 生产实现：用 engine `createChat` 开**一次性独立 session**，喂 `ConversationStrategy.buildSummaryPrompt`，collect 收敛为字符串（非流式），用完 dispose——不污染对话 session 上下文
- prompt（`buildSummaryPrompt`，纯函数可单测）：角色「对话摘要器」，输出 ≤200 字，保留：用户目标/偏好、已确认的事实、未决问题；不复述对话原文。输入 = 旧摘要（可为空）+ 被移出消息（用户:/助手: 行）

### 3.4 context-full 自愈（Task 1，独立于压缩）

- `generateResponse` 的 catch 中识别 `LlamaDecodeException`（兜底匹配 message 含 `context full`）→ 强制执行一次激进重建（只保留最后 4 条，**内容必须真正减少**，否则同 prompt 依旧撑爆）→ 本轮仍吐降级文案，**下一轮恢复**
- 与既有 `finally { _skipNextHistoryAi = true }` 兼容：失败轮 assistant 本就不登记

### 3.5 兜底链

```
压缩触发 → 摘要生成成功 → 摘要卡 + 预算窗口（新常态）
        → 摘要生成失败/超时 → 回落现状：丢弃 dropped，纯窗口重建
context full 自愈 → 强制 compact → 下一轮恢复
估算仍偏低撑爆 → 兜底 3 兜住（会话不再永久卡死）
```

## 4. Task 划分（详见 plan）

1. 阈值修正 + 每条消息 overhead + context-full 自愈（纯防御，独立可提交）
2. `buildSummaryPrompt` + Summarizer 抽象与生产实现（独立 session）
3. `_truncateContext` → 预算驱动 compact（接 Summarizer，含兜底回落）
4. 收尾（全量验证 / 提交 / 文档 / 冒烟项）

## 5. 范围外（明确不做）

- 异步预压缩（回复结束后台生成摘要）
- 摘要随 Conversation 持久化 / 跨启动恢复
- 云端模式任何改动（云端历史窗口由服务端/请求侧处理）
- KV cache 平移（插件不支持，见 §1）
- StrategyBrief / goals 注入链路的调整

## 6. 测试策略

| 对象 | 方式 |
|---|---|
| buildSummaryPrompt | 纯函数单测：含旧摘要/不含、含 dropped 消息行格式 |
| Summarizer | fake 注入：合并语义（旧摘要+dropped 都进 prompt）、返回空/抛异常 → 回落纯窗口 |
| compact | fake Session + fake Summarizer：预算装窗（长消息少留/短消息多留）、最后 2 条保底、摘要卡进新 session、dropped 为空时跳过摘要生成、估算重置 |
| 自愈 | fake Session.generate 抛 LlamaDecodeException → 当轮降级文案 + session 已重建、下轮可用 |
| 回归 | 更新现有「保留最近 12 条」相关断言为预算语义；`flutter analyze` 0 + 全量 `flutter test` 绿 |

## 7. 风险与等价性检查

- **当前问题丢失风险**：compact 时最后 2 条强制保留，当前用户消息原文必在新 session（§3.2）
- **摘要幻觉**：2B 模型摘要质量有限——摘要卡标明「此前对话摘要」，且仅作上下文补充；关键事实以 goals/strategy_brief 管线为准（已有闭环）
- **触发轮延迟**：同步摘要几秒级，用户感知为该轮回复偏慢（已确认接受，v1 不做预压缩）
- **估算漂移依旧存在**：overhead 常数 + margin 只是收敛误差，自愈（§3.4）是最终保险，二者缺一不可
- **去重/think 剥离/diff append 语义**：本迭代全部不动
