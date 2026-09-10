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

### D1. LocalChatClient 构造不 fail-fast ⭐ 建议优先（bug 级）

- 位置：`lib/features/chat/engine/local_chat_client.dart` 构造函数
- 问题：只注入 `sessionFactory` 而无 `engine` 时，默认 summarizer 闭包在**首次触发压缩时**才抛 `StateError`，构造期无感知
- 建议：构造期校验「sessionFactory 与 engine 至少其一 + summarizer 可用性」的组合合法性，非法组合直接抛
- 状态：[ ]

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

### D4. 单例测试耦合

- 位置：`ChatProvider` 构造直接读 `SettingsRepository.instance` / `LlamaService.instance`
- 问题：测试被迫 `setUpAll` 初始化单例；已有 `_clientFactory` 注入缝可顺势扩展
- 建议：把两个单例也变成可注入依赖
- 状态：[ ]

---

## 三、重复与漂移（待逐个处理）

| # | 问题 | 位置 | 状态 |
|---|---|---|---|
| P1 | `maxTokens: 2048` 两处不同源 | `strategist_extractor.dart:111` 裸字面量 vs `local_chat_client.dart` `_maxTokens` 常量 | [ ] |
| P2 | 上下文预算公式两套口径 | extractor `nCtx*0.85` vs client `nCtx−max−margin` | [ ] |
| P3 | 服务端端口 3000 两端各定义 | 客户端 `constants.dart` `serverBaseUrl` vs 服务端 `index.js` | [ ]（跨端常量，可能只能注释互指） |
| P4 | 生成长度上限不齐 | 服务端 `max_tokens: 1024` vs 客户端 2048 | [ ] |
| P5 | `tool/llama_integration_test.dart` 漂移 | 仍用旧「苏格拉底教练」人设 + `nCtx: 2048`，与现行 `ConversationStrategy` 不一致 | [ ] |

---

## 四、有意设计，保留不动 🔒

- **服务端 `CHAT_SYSTEM_PROMPT` 兜底**（`llm-engine.js`）：候选②拍板的降级路径，兼容不带 systemPrompt 的旧客户端。已知代价是与客户端人设漂移；若在意可把兜底缩成一句中性提示。
- **`/api/debug-push`**：已有 `NODE_ENV === 'production' → 404` 守卫。
- **`LlamaService.dispose()`**：生命周期钩子，保留合理。
