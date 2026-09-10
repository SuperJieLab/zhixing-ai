# 知行AI — 云端 BYOK 直连实施计划

> 状态：待执行
> 设计：`docs/plans/2026-09-10-byok-cloud-design.md`（已确认：BYOK 直连、服务端对话链路退场、参数不下发）
> 纪律：每 Task 实现 → 自查 → 改动留工作区，由用户确认后提交；不自动 commit。
> 测试命令（沙箱代理会拦截 flutter_tester）：
> `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy NO_PROXY='*' no_proxy='*' flutter test`

## Task 1：服务端瘦身（删对话转发链路，独立可提交）

**文件**
- 删 `server/src/routes/chat.js`；`server/src/index.js` 摘除 `chatRouter` require 与 `/api/chat` 挂载
- 删 `server/src/services/llm-engine.js` 中：`streamChatCompletion`、`CHAT_SYSTEM_PROMPT`、`CHAT_MAX_OUTPUT_TOKENS`（仅转发用）；保留 `analyzePushDecision` 与其硬编码 URL
- 删 `server/src/services/sse-parse.js`（`extractDeltas` 随转发链路成死代码）+ `server/tests/sse-parse.test.js` + `server/tests/chat-route.test.js`
- 核查：`DEEPSEEK_BASE_URL` 常量/导出在删除后是否还有消费方（push.test.js 的 mock 机制），无则删

**验证**
- [ ] `npm test` 全绿（push/wsHub 用例不受波及）；`grep -r "api/chat\|streamChatCompletion\|CHAT_SYSTEM_PROMPT" server/src` 零残留
- [ ] 手动：`npm start` 起服务，`/api/sync`、`/ws` 行为不变

## Task 2：配置三件套（SettingsRepository + Provider + SettingsPage）

**文件**
- 改 `lib/core/data/repository/settings_repository.dart`：
  - 3 个 key：`cloud_api_base_url` / `cloud_api_key` / `cloud_model_name`（String，默认 `''`）+ 对应 getter/setter
  - 派生 getter `bool get isCloudApiConfigured`（三项 trim 后均非空）
- 改 `lib/features/settings/providers/settings_provider.dart`：透传 3 组 getter/setter + `isCloudApiConfigured`
- 改 `lib/features/settings/settings_page.dart`：
  - 云端模式开关下新增配置区：3 个 `TextField`（API 地址 / API Key `obscureText` / 模型名），placeholder 给 DeepSeek 示例（`https://api.deepseek.com` / `sk-...` / `deepseek-chat`）
  - 开启云端模式时 `!isCloudApiConfigured` → 弹窗「请先补全 API 配置」，不置位开关（既有 consent 弹窗在配置齐全后照常走）
  - 文案修正：开关 subtitle 与 consent 弹窗去掉「经服务端转发至 DeepSeek」→「直连你配置的模型 API，不经过本应用服务端」

**验证**
- [ ] `isCloudApiConfigured` 单测：空/部分/全配三态
- [ ] 门禁：未配置时开开关 → 弹窗且开关保持关；配置齐全 → consent → 开启
- [ ] `flutter analyze` 0

## Task 3：CloudChatClient 直连改造 + ChatProvider 接线

**文件**
- 改 `lib/features/chat/engine/cloud_chat_client.dart`：
  - 构造参数改为必传 `CloudApiConfig`（新值类：baseUrl/apiKey/modelName，或三散参——实现时取简洁者）+ 保留 `frameTimeout`/`strategy`
  - 请求：`POST {baseUrl}/chat/completions`（请求级完整 url，Dio BaseOptions 不再依赖 serverBaseUrl），头加 `Authorization: Bearer`；body 为 `{model, messages: [system 人设 + 窗口], stream: true}`——**删** `systemPrompt` 顶层字段与 `error` 帧解析
  - 响应：非 200 → 抛错（文案含 status）；delta 取 `choices[0].delta.content`（缺失/空跳过）
  - 窗口逻辑（round==0 过滤 + 尾部 10 条）、`SseBuffer`、空闲超时、stop/dispose 全部不动
- 改 `lib/features/chat/providers/chat_provider.dart`：`_defaultClientFactory` cloud 分支读 `SettingsRepository` 三件套，未配置（理论上被 Task 2 门禁挡住，防御性保留）→ 抛错走既有 Mock 降级
- 改 `test/features/chat/engine/cloud_chat_client_test.dart`：mock 响应帧改 OpenAI 格式；A–E 用例语义保留；新增：请求体断言（system 首条 + model + Authorization 头）、非 200 抛错、delta.content 缺失跳过

**验证**
- [ ] 上述新增/改造用例绿；`flutter analyze` 0
- [ ] 全量 `flutter test` 绿

## Task 4：收尾

- [ ] 全量回归：`flutter analyze` 0 + 全量 `flutter test` + `npm test`
- [ ] 提交：Task 1 一笔（服务端瘦身）；Task 2+3 一笔（BYOK 直连功能）——按用户确认节奏
- [ ] 更新 `MEMORY.md`：BYOK 直连落地 + 服务端纯业务化记录（含「候选②透传机制退役」的认知修正）
- [ ] 手工冒烟项（用户侧）：配置真实 key 直连 DeepSeek 流式对话、停止生成、错误 key 看 401 降级、切回本地模式
- [ ] README/PROJECT.md 若有「经服务端转发」表述则同步修正

## 依赖关系

```
Task 1（独立）   Task 2 ──▶ Task 3 ──▶ Task 4
```

Task 1 与客户端三件套无代码依赖（客户端测试用本地 mock），先做纯为提交节奏清晰；Task 3 的直连实现是功能核心；Task 2 的门禁是 Task 3 防御分支的前置体验层。

## 关键实现备忘（从设计文档摘录）

- `SseBuffer` 零改动复用：OpenAI 帧同为 `data:` 前缀 + `[DONE]` 粘性，缓冲状态机协议无关
- 请求失败语义变化：自定义 error 帧消失，改「非 200 → 抛错（含 status）」；流中 JSON 解析失败照旧 `_safeError`
- `baseUrl` 存根地址形态，客户端拼 `/chat/completions`；Dio 用请求级完整 url
- 人设唯一出处不变：`ConversationStrategy.buildSystemPrompt(existingGoals)` 直连放 `messages[0]`
- 推送决策 `analyzePushDecision` 是服务端自有业务（cron），保留不动；删转发时注意其测试 mock 机制
- 云端模式「未配置」双保险：设置层门禁（Task 2）+ 工厂防御抛错（Task 3），运行时降级链（Timeout → 重试提示 / 无产出 → Mock）不变
