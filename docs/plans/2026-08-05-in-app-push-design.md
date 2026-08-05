# 知行AI — 站内推送联动设计（服务端触发 · 客户端站内展示）

> 状态：设计已确认（2026-08-05 brainstorming 流程产出）
> 关联：`docs/plans/2026-07-20-server-push-plan.md`（旧路线，本文档替代其「真下发」环节）

## 1. 背景与目标

产品闭环是「对话 → 提取目标/策略 → Dashboard 追踪 → 提醒」。
服务端（`server/`）已有完整能力：接收端侧上报（`POST /api/sync`）、每 30 分钟 cron 跑**规则引擎**或 **DeepSeek LLM** 决策。
**唯一缺口**：`push.js` 的 `sendPush()` 还是 `console.log` 占位，决策结果发不出去。

本设计要补上「真下发」，但**不走 FCM/APNs 系统推送**（旧 plan 路线），而是做**站内推送联动**：
服务端决策后**主动**经 WebSocket 把提醒推到客户端，客户端在**应用内**弹横幅展示。

核心收益：
- 把现有 Server 决策能力真正用起来，形成 设定→追踪→**服务端触发提醒** 闭环。
- 不需要 APNs / FCM / firebase-admin（系统推送的上架与证书负担），纯靠一条长连接。
- 与「端侧离线、隐私零上传」定位不冲突：上报的仍是结构化摘要（title/deadline），不是对话原文；WS 只传 token（身份）+ 提醒文案。

## 2. 已确认的决策（brainstorming 三问）

| 决策点 | 结论 |
|---|---|
| **v1 范围** | 最小可跑通：服务端 WS 真下发 + 客户端连上弹横幅。**不做**历史消息列表、**不做**断线补发队列。 |
| **下发机制** | **WebSocket 长连接**。服务端维护 `token → socket` 映射，决策后主动 `ws.send`，最贴合「服务端触发 / 联动」。 |
| **服务端地址** | **可配置常量**（默认 `http://localhost:3000`，真机联调改 Mac 局域网 IP）。HTTP 与 WS 共用同一份配置。 |

## 3. 架构总览

```
客户端 App                               Node Server
──────────                               ──────────
PushSocketService ──WS(/ws?token)──────▶ wsHub (token→Set<socket>)
  │                                          │
  │  ◀── ws.send({type:push,...}) ──────────┘  (cron 决策后主动推)
  │
SyncService ──POST /api/sync──────────▶ routes/sync (token→{goals,strategies,mode})
  │                                          │
  │                                     cron 每30分
  │                                          └─▶ push.js → rules-engine / llm-engine → sendPush → wsHub.pushToToken
  ▼
应用内横幅（SnackBar / Overlay）
```

设备身份 = 现有 `device_token`（来自 `PushService().getToken()`）。
WS 连上来带的 `token` 必须与 `/api/sync` 上报的 `device_token` 一致，服务端才能匹配该设备的 goals/strategies。

## 4. 服务端改动（`server/`）

- **依赖**：新增 `ws`（WebSocket 库）。
- **`index.js`**：将 HTTP server 升级为「HTTP + WebSocket 同源」。在同一 `http.Server` 上挂 `WebSocketServer`，路径 `/ws`。连接时从 `req.url` 解析 `?token=`，调用 `wsHub.register(token, ws)`；关闭/出错时 `wsHub.unregister`。
- **新增 `services/wsHub.js`**：连接注册中心。
  - `clients: Map<token, Set<ws>>`（一个 token 可能多端/多标签）。
  - `register(token, ws)` / `unregister(token, ws)` / `pushToToken(token, payload)`。
  - `pushToToken`：遍历该 token 的活跃 socket，`ws.send(JSON.stringify(payload))`；无活跃 socket 时**直接跳过**（v1 不做队列）。
  - 该 map 由 `index.js` 拥有，`push.js` 引用，解决「决策模块 ↔ WS 模块」的连接问题。
- **`services/push.js` 的 `sendPush(token, notification)`**：从 `console.log` 占位改为
  `const delivered = wsHub.pushToToken(token, { type:'push', title, body, ts: Date.now() });`，返回 `delivered`。
  删除 firebase-admin 那段 TODO（站内不需要）。
- **`runRulesMode` / `runLLMMode`**：签名与调用不变（`sendPush(token, {...})` 已兼容），无需改。
- **（验证用）`POST /api/debug-push`**：仅 dev 暴露，手动触发一次对该 token 的推送，避免干等 30 分钟 cron。实现即调 `sendPush(test_token, {...})`。

## 5. 客户端改动（`lib/`）

- **依赖**：新增 `web_socket_channel`。
- **`lib/core/constants.dart`**：新增
  `static const String serverBaseUrl = 'http://localhost:3000';`
  （WS 用 `ws://` 替换 `http://` 前缀的辅助 getter）。
- **`lib/core/services/sync_service.dart`**：把写死的 `http://localhost:3000` 改成读 `serverBaseUrl`，HTTP 与 WS 共用。
- **新增 `lib/core/services/push_socket_service.dart`**：
  - 启动时用 `PushService().getToken()` 取设备标识。
  - `WebSocketChannel.connect(Uri.parse('$wsBaseUrl/ws?token=$token'))`。
  - 监听 `channel.stream`；收到 `{type:'push'}` → 通过回调 / 简单事件总线抛给上层。
  - **连接生命周期**：`main.dart` 启动后连一次；断开后由 `_scheduleReconnect` 固定 5s 退避重连（无 `AppLifecycleState` 监听，保持简单）。生命周期重连 / 指数退避留作后续演进。
  - 容错：连接失败 / `onDone` / `onError` → 退避重连，**绝不抛异常影响主流程**（沿用 SyncService「推送是锦上添花」原则）。
- **横幅展示（v1 最小）**：收到推送 → 经全局 `NavigatorKey` 触发 `ScaffoldMessenger` 的 SnackBar（或 `OverlayEntry` 顶部条）。优先 SnackBar，能验证「站内推送」效果即可。后续可升级为自定义顶部横幅。
- **`lib/main.dart`**：在 `SettingsRepository.initialize()` 之后启动 `PushSocketService` 连接。

## 6. 数据流

1. App 启动 → `PushSocketService` 连 `ws://host/ws?token=`。
2. Dashboard 加载 → `SyncService.syncDashboard()` 自动 `POST /api/sync`（已有），带 token + mode + goals/strategies。
3. 服务端 cron 每 30 分 → `runRulesMode`/`runLLMMode` → `sendPush` → `wsHub.pushToToken` → 经 WS 推回该 token。
4. 客户端收到 → 弹应用内横幅。

## 7. 容错与边界

- 服务端挂了 / WS 连不上 → 退避重连，App 不崩。
- **断线期间产生的推送直接丢弃**（v1 约定：站内只在 App 连接期间送达；不做补发队列）。
- `mode` 决定走规则还是 LLM：由 `SettingsRepository.useAiOptimizedPush` 控制，沿用现有逻辑。
- 隐私：WS 仅传 token + title/body；上报数据仍是结构化摘要，非对话原文（与现状一致）。

## 8. 验证手段（关键：查产物不查文本）

- 服务端加 `POST /api/debug-push` 路由，手动触发一次推送（不必等 30 分钟）。
- 客户端跑 iOS simulator（`serverBaseUrl = localhost`）：
  - 用 `wscat` 或 node 脚本连 `ws://localhost:3000/ws?token=test`，再 `curl -XPOST localhost:3000/api/debug-push -d '{"device_token":"test","title":"x","body":"y"}'`。
  - 预期：服务端日志打 `delivered: true`，App 真弹横幅。
- `flutter analyze lib/` 零 error。

## 9. 明确不在 v1 范围（v2 候选）

- 站内消息中心 / 历史列表（持久化回看）。
- 服务端断线补发队列（重连后补推错过的提醒）。
- 系统推送（APNs / FCM）：若未来要「App 关了也弹」，再走旧 plan 的 FCM 路线，与本设计正交。
- 设备级鉴权：v1 以 `device_token` 为弱身份，不做鉴权（MVP）。

## 10. 实现安排

设计确认后：用 `superpowers:using-git-worktrees` 建隔离分支，再用 `superpowers:writing-plans` 拆成任务级实现计划，按「先服务端（WS + 真下发）→ 后客户端（连接 + 横幅）→ 端到端验证」顺序落地。
