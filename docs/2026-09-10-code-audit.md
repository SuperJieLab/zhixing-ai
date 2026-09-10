# 代码审查问题清单（2026-09-10）

> 来源：全项目死代码 + 设计合理性审查（Explore 子代理扫描 + 逐条 grep 复核）。
> 本文档为追踪清单：每项处理完勾选并在结果列补 commit hash。
> 分层规范（page 不碰 engine/repository、跨 feature 隔离）核查无违规，未列入。

## 状态图例

- [ ] 待处理
- [x] 已完成
- 🔒 有意设计，保留不动（勿误删）

---

## 一、死代码（已全部删除）

| # | 位置 | 符号 | 状态 | 结果 |
|---|---|---|---|---|
| 1 | `lib/core/constants.dart` | `appName` / `appTagline` / `isModelAvailable()`（连带 `dart:io` import） | [x] | |
| 2 | `lib/core/engine/llama_service.dart:54` | `poolSize` getter | [x] | |
| 3 | `lib/core/services/push_service.dart:36` | `token` getter（`_token` 字段保留，`getToken()` 仍用） | [x] | |
| 4 | `lib/core/model_manager.dart:28` | `hasModel` getter | [x] | |
| 5 | `lib/core/repository/dashboard_repository.dart:41` | `getGoalByTitle` | [x] | |
| 6 | `lib/core/repository/dashboard_repository.dart:72` | `getStrategiesByGoal` | [x] | |
| 7 | `lib/core/engine/conversation_service.dart:19` | `loadConversation` | [x] | |
| 8 | `lib/core/repository/conversation_repository.dart:190` | `getById`（loadConversation 死链连带） | [x] | |
| 9 | `lib/core/models/available_model.dart:24` | `downloadUrl` getter（代码只用 `mirrorUrl`） | [x] | |

验证：`flutter analyze` 0、全量 `flutter test` 119/119。

---

## 二、设计问题（待逐个处理）

### D1. LocalChatClient 构造不 fail-fast ⭐ 已修复

- 位置：`lib/features/chat/engine/local_chat_client.dart` 构造函数
- 问题：只注入 `sessionFactory` 而无 `engine` 时，默认 summarizer 闭包在**首次触发压缩时**才抛 `StateError`
- 修正认知：该异常实际被 `_compactContext` try/catch 接住回落纯丢弃——真实故障面是「静默质量降级」而非崩溃
- 落地：构造期校验 engine/sessionFactory 至少其一（`ArgumentError`）；summarizer 改为**显式可空**（sessionFactory-only 时为 null，压缩时明确 warn 回落），不再用抛异常闭包伪装能力
- 状态：[x]

### D2. 本地 stop() 无法真中断引擎

- 位置：`local_chat_client.dart` stop 实现 / ChatClient 接口
- 问题：Provider 取消订阅只是丢弃输出流，底层 llama 生成继续跑完（CPU 白烧）；接口携带 no-op 成员
- 建议：短期补注释声明「本地为尽力而为取消」；长期看插件是否暴露中断 API
- 状态：[ ]

### D3. 压缩同步阻塞首 token

- 位置：`generateResponse` 内 compact 调用点
- 问题：超阈值那轮，用户要先等完整摘要推理（2B 模型数秒）才见到第一个字
- 建议：v1 已拍板接受；后续可优化为「轮次结束后台预压缩」
- 状态：[ ]（低优先级，已拍板 v1 接受）

### D4. 单例测试耦合 ⭐ 已修复

- 位置：`ChatProvider` 构造直接读 `SettingsRepository.instance.chatCloudMode`
- 问题：测试被迫 `setUpAll` 初始化单例才能构造 Provider
- 落地：构造期不再碰单例——`mode` 显式传入时直接用；缺省时延迟到 `_defaultClientFactory`（即 `loadModel` 时）读取。`LlamaService.instance` 本就只在默认工厂内被触达，注入 `clientFactory` 的测试全程零单例依赖
- 状态：[x]

---

## 三、重复与漂移（已全部修复）

| # | 问题 | 位置 | 状态 |
|---|---|---|---|
| P1 | `maxTokens: 2048` 两处不同源 | 收口为 `AppConstants.localMaxTokens`（端侧专用），客户端/提取器共用；云端**不共享**（见 P4 修订） | [x] |
| P2 | 上下文预算公式两套口径 | 统一为 `AppConstants.localInputBudget`（nCtx−生成上限−余量）；extractor 旧公式 `nCtx*0.85−overhead−200` 存在溢出隐患（输入最满时 + 2048 生成 > nCtx），已修复 | [x] |
| P3 | 服务端端口 3000 两端各定义 | 跨端无法真正单源，两侧注释互指（client `serverBaseUrl` ↔ server `index.js PORT`） | [x] |
| P4 | 生成长度上限不齐 | ~~对齐 2048~~ → **修订**：云端约束独立于端侧，服务端自定义 `CHAT_MAX_OUTPUT_TOKENS = 4096`（DeepSeek 默认档，API 最高 8192）；推送决策的 200 为独立语义，保留 | [x] |
| P5 | `tool/llama_integration_test.dart` 漂移 | 人设改用 `ConversationStrategy().buildSystemPrompt()`，`nCtx`/`nThreads` 引用常量，模型路径对齐 `AvailableModel.available.first`（Qwen3.5-2B） | [x] |

> **P1/P4 后续修订（同日）**：用户指出云端模型能力更强，参数限制不应与本地共享。全部 LLM 常量更名 `local*` 前缀（`localContextSize`/`localMaxTokens`/`localInputBudget` 等）并注明端侧专用；云端输出上限由服务端 `CHAT_MAX_OUTPUT_TOKENS` 独立定义。跨端「对齐」仅适用于端口这类连接配置，不适用于模型能力参数。

---

## 四、有意设计，保留不动 🔒

- **服务端 `CHAT_SYSTEM_PROMPT` 兜底**（`llm-engine.js`）：候选②拍板的降级路径，兼容不带 systemPrompt 的旧客户端。已知代价是与客户端人设漂移；若在意可把兜底缩成一句中性提示。
- **`/api/debug-push`**：已有 `NODE_ENV === 'production' → 404` 守卫。
- **`LlamaService.dispose()`**：生命周期钩子，保留合理。
