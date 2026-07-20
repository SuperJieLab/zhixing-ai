# 服务端推送：Flutter 与 Node.js 连接全链路

> 学习笔记 | 2026-07-20
> 从零理解：Flutter App 怎么和服务端"说话"

---

## 一、架构全景

```
┌──────────────────────────────────────────────────────────┐
│  Flutter App（手机端）                                     │
│                                                          │
│  步骤 1  main.dart                                        │
│         PushService.initialize() → 获取设备 token          │
│                                                          │
│  步骤 2  DashboardProvider.load()                         │
│         从 sqflite 加载数据 → 自动触发 _syncToServer()      │
│                                                          │
│  步骤 3  SyncService.syncDashboard()                      │
│         打包 JSON → Dio HTTP POST                         │
│                    │                                     │
├────────────────────┼─────────────────────────────────────┤
│                    │  POST /api/sync                      │
│                    │  http://localhost:3000               │
│                    ▼                                     │
│  Node.js 服务端（电脑上运行）                                │
│                                                          │
│  步骤 4  routes/sync.js                                   │
│         接收 JSON → 存入内存 Map（deviceStore）            │
│                                                          │
│  步骤 5  node-cron 定时扫描（每 30 分钟）                   │
│         取出所有设备数据 → 推送决策                         │
│                                                          │
│  步骤 6  services/push.js                                 │
│         ├── 规则模式 (OFF) → rules-engine.js               │
│         │     "deadline 3 天内？→ 推送"                    │
│         └── LLM 模式 (ON)  → llm-engine.js                │
│               "DeepSeek 分析上下文 → 生成推送文案"           │
│                         ↓                                │
│                console.log 占位（真实：APNs / FCM）         │
└──────────────────────────────────────────────────────────┘
```

---

## 二、三个基础概念（Node.js 小白向）

做移动端的人第一次接触服务端，最容易困惑的就是"Flutter 怎么找到 Node.js"。

### 2.1 HTTP 请求 — 手机和电脑之间传消息的"快递"

Flutter App 要告诉服务端"我有新数据了"，它不会直接调用服务端的函数——它们跑在不同的进程里。

实际的做法是：Flutter 发一个 **HTTP POST 请求**，把数据打包成 JSON，寄到服务端的地址。服务端收到后解析 JSON，做自己的逻辑，然后回一个"收到了"的确认。

```
Flutter App                           Node.js 服务端
──────────                           ──────────────
POST /api/sync  ──────────────────→  收到请求
  body: {                             解析 req.body
    goals: [...]                      存入 deviceStore
    strategies: [...]                 回复 "ok"
  }
          ←────────────────────────  { success: true }
```

### 2.2 端口（Port）— 一台电脑上的"房间号"

一台电脑可以同时跑很多程序（微信、浏览器、终端……）。当 HTTP 请求到达电脑时，操作系统需要知道"这个请求给哪个程序处理"。

**端口号**就是解决这个问题的。就像一栋大楼里的房间号：

- `localhost:3000` → 送给监听 3000 端口的程序（我们的 Node.js 服务端）
- `localhost:8080` → 送给监听 8080 端口的程序（另一个服务）

`localhost` 表示"本机"。开发和测试阶段 Flutter App 和服务端跑在同一台电脑上，所以用 localhost。真要部署到服务器上时，换成公网 IP 或域名。

### 2.3 JSON — Flutter 和 Node.js 的"通用语言"

Flutter 用 Dart，Node.js 用 JavaScript——两种不同的语言，数据结构也不一样。JSON (`{"key": "value"}`) 是它们的"通用语言"：

```dart
// Flutter 端：Dart Map → JSON 字符串
final data = {
  'device_token': 'mock_token_123',
  'goals': [{'title': '跳槽', 'deadline': '2026-08-01'}],
};
dio.post('/api/sync', data: data);  // dio 自动把 Map 转成 JSON
```

```javascript
// Node.js 端：express.json() 中间件自动把 JSON 字符串 → JS 对象
router.post('/', (req, res) => {
  const { device_token, goals } = req.body;
  // goals[0].title === '跳槽'  ← 已经是 JS 对象了
});
```

---

## 三、六步连接流程详解

### 步骤 1：App 启动 — 获取设备"身份证"

```dart
// lib/main.dart
PushService().initialize();
```

`PushService` 尝试从 Firebase 获取一个 **FCM token**（Firebase Cloud Messaging 的设备标识）。这个 token 就像一个"设备身份证号"，服务端用这个号知道推送要发到哪台手机。

MVP 阶段 Firebase 还没配置，所以 catch 异常后生成一个 `mock_token_xxx` 作为占位符。后续配置好 Firebase 后，这里就能拿到真实 token，不用改任何业务代码——这就是**渐进式集成**的思想。

### 步骤 2：进入 Dashboard — 自动触发同步

```dart
// lib/features/dashboard/providers/dashboard_provider.dart
Future<void> load() async {
  final goals = await _repo.getAllGoals();
  final strategies = await _repo.getAllStrategies();
  // ... 更新状态 ...
  _syncToServer();  // 数据加载完自动上报
}
```

每次进入 Dashboard 页面（或数据变更后重新加载），`load()` 末尾自动调 `_syncToServer()`。用户不需要手动点"同步"按钮——这对业务代码完全透明。

### 步骤 3：SyncService — 打包数据，发 HTTP 请求

```dart
// lib/core/services/sync_service.dart
await _dio.post('/api/sync', data: {
  'device_token': token,    // "我是哪台手机"
  'mode': 'rules',          // "用什么模式推送"
  'goals': [...],           // 目标数据
  'strategies': [...],      // 策略数据
});
```

`dio` 是 Flutter 社区最流行的 HTTP 客户端库。它把 Dart 的 Map 自动转成 JSON 字符串，发给 `http://localhost:3000/api/sync`。

超时设为 5 秒：移动端网络不稳定，快速失败优于长时间等待。

**容错**：如果服务端没启动（比如你忘了 `npm start`），catch 后用 `AppLogger` 记录一条日志，App 照常运行。推送是"锦上添花"，不能因为它挂了 App 跟着崩——这叫**优雅降级**。

### 步骤 4：服务端接收 — Express 解析请求

```javascript
// server/src/routes/sync.js
router.post('/', (req, res) => {
  const { device_token, mode, goals, strategies } = req.body;
  deviceStore.set(device_token, { mode, goals, strategies });
  res.json({ success: true });
});
```

Express 的 `express.json()` 中间件自动把 HTTP body 里的 JSON 字符串解析成 `req.body` 这个 JS 对象。然后存到内存 Map 里（key = device_token），回复 `{ success: true }` 表示收到。

**为什么用内存 Map 而不是数据库？**

设计原则是"服务端不持久化用户数据"——隐私保护。App 每次进 Dashboard 都会重新上报一次数据，服务端重启后数据丢了也没关系。MVP 阶段够用。

### 步骤 5：定时扫描 — node-cron 闹钟

```javascript
// server/src/index.js
cron.schedule('*/30 * * * *', async () => {
  const store = syncRouter.getStore();
  await runRulesMode(store);   // 规则模式设备
  await runLLMMode(store);     // LLM 模式设备
});
```

`node-cron` 像一个闹钟，每 30 分钟自动触发一次。`'*/30 * * * *'` 是 cron 表达式（每 30 分钟），从 deviceStore 取出所有设备的数据，分别交给两个引擎处理。

### 步骤 6a：规则引擎 — 纯 if-else 判断

```javascript
// server/src/services/rules-engine.js
// 规则 1: deadline 在未来 3 天内？→ 推送
// 规则 2: 有未完成策略但没设截止日期 → 每天最多推送一次
// 规则 3: 没有任何未完成策略 → 不推送
```

纯函数，不依赖网络、不访问数据库。面试可聊：为什么用纯函数而非类？——无状态、易测试、无副作用。

### 步骤 6b：LLM 引擎 — DeepSeek 智能决策

```javascript
// server/src/services/llm-engine.js
const response = await fetch('https://api.deepseek.com/chat/completions', {
  body: JSON.stringify({
    model: 'deepseek-chat',
    messages: [{ role: 'user', content: prompt }],
  }),
});
```

把目标数据 + 策略数据构造成 Prompt，发给 DeepSeek API。大模型会分析上下文，判断"现在是否需要推送"以及"推送什么内容"。

**容错设计**：
- 无 API Key → 直接返回 null（不推送，不崩溃）
- API 调用失败 → catch 后返回 null
- JSON 解析失败 → catch 后返回 null

这种**多层降级**的思路面试时可以展开讲。

---

## 四、文件职责速查

| 文件 | 做什么 | 被谁调用 | 调用谁 |
|:--|:--|:--|:--|
| `server/src/index.js` | Express 入口 + cron 调度 | `npm start` | sync.js, push.js |
| `server/src/routes/sync.js` | 接收 Flutter 上报的数据 | Flutter POST /api/sync | — |
| `server/src/services/push.js` | 推送决策分发（总调度） | index.js (cron) | rules-engine, llm-engine |
| `server/src/services/rules-engine.js` | 规则模式：deadline 检查 | push.js | — |
| `server/src/services/llm-engine.js` | LLM 模式：DeepSeek API | push.js | api.deepseek.com |
| `lib/core/services/push_service.dart` | FCM token 管理（单例） | main.dart, sync_service | firebase_messaging |
| `lib/core/services/sync_service.dart` | HTTP 数据同步（单例） | dashboard_provider | dio, push_service |

---

## 五、你可能想追问的

### Q: 为什么不用 WebSocket 做长连接？

推送场景不需要实时双向通信。App 上报数据 → 服务端定时扫描 → 通过 APNs/FCM 推送到手机——这个链路里 App 和服务端之间只需要一次 HTTP POST。WebSocket 适合聊天、实时协同编辑等需要"服务端随时主动推数据给 App"的场景。

### Q: 为什么服务端用 Express 而不是 Go/FastAPI？

Express 学习成本最低——你作为移动端工程师，JavaScript 语法最接近 Dart，不需要额外学 TypeScript 类型系统或 Python 生态。MVP 阶段开发效率优先。如果将来需要更高并发，迁移到 Go 或 FastAPI 的成本也在可控范围内。

### Q: localhost:3000 在真机上能访问吗？

不能。`localhost` 指向"本机"——真机上运行 App 时，`localhost` 指向的是手机自己，不是你的电脑。

真机调试时需要：
1. 电脑和手机连同一个 WiFi
2. 把 `baseUrl` 改成电脑的局域网 IP（如 `http://192.168.1.100:3000`）
3. 或者部署到公网服务器，用域名访问

### Q: 数据上报到服务端，隐私怎么保证？

1. **不传对话原文**——只传结构化摘要（title + deadline + category）
2. **默认不上传语义向量**——用户需主动开启 AI 优化推送
3. **服务端不持久化**——内存 Map，重启即清空
4. **首次开启 AI 优化时弹窗说明数据范围**
