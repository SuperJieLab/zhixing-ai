# 知行AI — 本地对话上下文压缩实施计划

> 状态：待执行
> 设计：`docs/plans/2026-09-09-context-compaction-design.md`（已确认：方案 A 滚动摘要；预算驱动窗口，不固定 12 条）
> 纪律：每 Task 实现 → 自查 → 改动留工作区，由用户确认后提交；不自动 commit。
> 测试命令（沙箱代理会拦截 flutter_tester）：
> `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy NO_PROXY='*' no_proxy='*' flutter test`

## Task 1：阈值修正 + context-full 自愈（纯防御，独立可提交）

**文件**
- 改 `lib/features/chat/engine/local_chat_client.dart`：
  - 阈值默认值：`modelContextSize * 0.75` → `modelContextSize - _maxTokens - _contextMargin`（新增 `_contextMargin = 384`）
  - diff append 时每条消息累加 `_perMessageOverhead = 16`（template 开销）
  - `generateResponse` catch 中识别 `LlamaDecodeException`（兜底 message 含 `context full`）→ `await _compactContext(force: true)`（本 Task 先复用现 `_truncateContext` 逻辑强制重建），本轮仍吐降级文案
- 改 `test/features/chat/engine/local_chat_client_test.dart`：阈值相关用例按新语义更新

**验证**
- [ ] 单测：注入小阈值触发重建（新默认值算法不依赖真实 nCtx）；generate 抛 context-full 异常 → 当轮降级文案 + session 已重建 + 下轮可继续
- [ ] `flutter analyze` 0；全量 `flutter test` 绿

## Task 2：摘要生成器（Summarizer）

**文件**
- 改 `lib/features/chat/engine/conversation_strategy.dart`：新增纯函数 `String buildSummaryPrompt({required String previousSummary, required List<({String role, String content})> dropped})`（≤200 字约束、保留目标/偏好/已确认事实/未决问题、用户:/助手: 行格式）
- 改 `lib/features/chat/engine/local_chat_client.dart`：
  - `typedef Summarizer = Future<String> Function(String previousSummary, List<({String role, String content})> dropped);`
  - 生产实现 `_LlamaSummarizer`（或等价私有类）：engine `createChat` 一次性 session → addSystem(buildSummaryPrompt(...)) → addUser(原文拼装) → collect 收敛字符串 → dispose；异常向上抛由调用方兜底
  - `LocalChatClient` 构造参数加 `Summarizer? summarizer`（测试缝），默认为生产实现

**验证**
- [ ] `buildSummaryPrompt` 纯函数单测：有/无旧摘要两态、dropped 行格式、不含对话外内容
- [ ] 生产 Summarizer 不便于真跑（FFI），以 fake 注入路径在 Task 3 覆盖；生产实现仅做编译级验证 + 代码走查（dispose 必达）

## Task 3：预算驱动 compact（替换 `_truncateContext`）

**文件**
- 改 `lib/features/chat/engine/local_chat_client.dart`：
  - `_truncateContext` → `_compactContext({bool force = false})`：
    - 移除 `keepCount = 12` 固定值；从尾部往前按预算装窗（base = system + 摘要卡估算；**至少保留最后 2 条**）
    - dropped 非空 → `summarizer(_summary, dropped)` 成功则更新 `_summary`（截断至 200 字上限），失败/空 → 回落纯窗口（丢弃 dropped，不生成摘要）
    - 重建 session：`addSystem(systemPrompt)` → `_summary` 非空时 `addSystem('【此前对话摘要】\n$_summary')` → 依序 append kept
    - `_estimatedTokens = 重算`（含摘要卡）
  - 触发点不变：`_estimatedTokens > _truncateThreshold`；Task 1 的自愈改调 `_compactContext(force: true)`
- 改 `test/features/chat/engine/local_chat_client_test.dart`：新增/更新 compact 用例

**验证**
- [ ] 单测（fake Session + fake Summarizer）：
  - [ ] 预算装窗：短消息多留/长消息少留，窗口大小随预算浮动（不再断言 12 条）
  - [ ] 最后 2 条保底：即使超预算也保留（当前问题原文可见）
  - [ ] 摘要合并语义：旧摘要 + dropped 都进 summarizer 入参；摘要卡写入新 session
  - [ ] dropped 为空（仅重建）时跳过摘要生成
  - [ ] summarizer 抛异常/返回空 → 回落纯窗口，不阻塞生成
  - [ ] 既有语义不回归：diff 增量、`_skipNextHistoryAi`、去重改写仅 session 侧、think 剥离
- [ ] `flutter analyze` 0；全量 `flutter test` 绿

## Task 4：收尾

- [ ] 全量回归：`flutter analyze` 0 + 全量 `flutter test` 绿 + `npm test`（server 18/18，确认无波及）
- [ ] 提交：Task 1 一笔（防御修复）；Task 2+3 一笔（压缩功能）——按用户确认节奏
- [ ] 更新 `MEMORY.md`：上下文压缩落地记录（参数、compact 算法、兜底链）
- [ ] 手工冒烟项（用户侧）：本地模式长对话压到阈值，观察摘要卡生效、触发轮延迟可接受、恢复会话正常
- [ ] 范围外备忘：异步预压缩、摘要持久化为后续候选

## 依赖关系

```
Task 1 ──▶ Task 2 ──▶ Task 3 ──▶ Task 4
```

Task 1 独立可交付（防御修复，无摘要概念）；Task 2 的 Summarizer 是 Task 3 compact 的依赖；Task 3 一次性切换触发逻辑。

## 关键实现备忘（从设计文档摘录）

- 报错建议的 `Request.shiftPolicy` 不可行：插件 Dart 层未暴露，恢复 = 重建 session
- 最后 2 条强制保留的原因：当前用户消息已 append 进旧 session，不能只存在于摘要里，否则模型看不到本轮问题原文
- 摘要生成必须用一次性独立 session（不污染对话 session 上下文），dispose 必达
- 兜底链顺序：摘要失败 → 纯丢弃窗口；context full → 强制 compact；估算漂移 → 自愈兜底
- 估算 overhead = 每条消息 +16（template 开销）+ margin 384（整体余量），均容忍误差，自愈是最终保险
- 云端模式零改动
