# 知行AI 站内推送联动 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 让服务端（规则/DeepSeek 决策）通过 WebSocket 主动把提醒推到客户端，客户端在应用内弹横幅——打通「设定→追踪→服务端触发提醒」闭环，不走 APNs/FCM。

**Architecture:** 服务端在现有 Express HTTP 上同源挂 `ws` WebSocketServer（`/ws?token=`），用 `wsHub` 维护 `token→Set<socket>`；`push.js` 的 `sendPush` 改为经 `wsHub.pushToToken` 真下发。客户端新增 `PushSocketService` 连 WS、监听 `{type:push}` 并触发应用内 SnackBar。设备身份复用现有 `device_token`。

**Tech Stack:** Node.js + `ws`（服务端）；Flutter + `web_socket_channel`（客户端）；`node --test`（服务端单测，零依赖）；`flutter test`（客户端单测）。

**设计依据：** `docs/plans/2026-08-05-in-app-push-design.md`
**前置：** 服务端 `server/`（express + cron + /api/sync + push.js 占位）、客户端 `SyncService`/`SettingsRepository`/`PushService` 已存在。

---

### Task 1: 服务端 `wsHub` 连接注册中心 + 单测

**Files:**
- Create: `server/src/services/wsHub.js`
- Create: `server/tests/wsHub.test.js`
- Modify: `server/package.json`（加 `test` 脚本）

**Step 1: 写失败测试 `server/tests/wsHub.test.js`**

```javascript
const test = require('node:test');
const assert = require('node:assert');
const { register, unregister, pushToToken } = require('../src/services/wsHub');

function fakeWs() {
  return { readyState: 1, sent: [], send(d) { this.sent.push(d); } };
}

test('pushToToken sends to registered sockets and returns count', () => {
  const ws = fakeWs();
  register('tok1', ws);
  const n = pushToToken('tok1', { type: 'push', title: 't', body: 'b' });
  assert.equal(n, 1);
  assert.equal(ws.sent.length, 1);
  assert.ok(ws.sent[0].includes('"title":"t"'));
  unregister('tok1', ws);
});

test('pushToToken returns 0 when no socket', () => {
  assert.equal(pushToToken('unknown', { type: 'push' }), 0);
});

test('pushToToken skips non-open sockets', () => {
  const ws = fakeWs();
  ws.readyState = 3; // CLOSED
  register('tok2', ws);
  assert.equal(pushToToken('tok2', { type: 'push' }), 0);
  unregister('tok2', ws);
});
```

**Step 2: 跑测试确认失败**

Run: `cd server && node --test tests/`
Expected: FAIL（`Cannot find module '../src/services/wsHub'`）

**Step 3: 最小实现 `server/src/services/wsHub.js`**

```javascript
// 连接注册中心：token -> 该设备的活跃 socket 集合
const clients = new Map();

function register(token, ws) {
  if (!clients.has(token)) clients.set(token, new Set());
  clients.get(token).add(ws);
}

function unregister(token, ws) {
  const set = clients.get(token);
  if (!set) return;
  set.delete(ws);
  if (set.size === 0) clients.delete(token);
}

// 向某 token 的所有活跃 socket 推送；返回实际送达数（无连接则返回 0）
function pushToToken(token, payload) {
  const set = clients.get(token);
  if (!set || set.size === 0) return 0;
  const data = JSON.stringify(payload);
  let n = 0;
  for (const ws of set) {
    if (ws.readyState === ws.OPEN) {
      ws.send(data);
      n++;
    }
  }
  return n;
}

module.exports = { register, unregister, pushToToken, clients };
```

**Step 4: 给 `server/package.json` 加 test 脚本**

在 `"scripts"` 中加：
```json
"test": "node --test tests/"
```

**Step 5: 跑测试确认通过**

Run: `cd server && node --test tests/`
Expected: PASS（3 passed）

**Step 6: 提交**

```bash
git add server/src/services/wsHub.js server/tests/wsHub.test.js server/package.json
git commit -m "feat(server): add wsHub connection registry with unit tests"
```

---

### Task 2: 把 WebSocket 挂到 HTTP 服务 + 加 debug-push 路由

**Files:**
- Modify: `server/src/index.js`（挂 WebSocketServer、register/unregister、`/api/debug-push`）

**Step 1: 修改 `server/src/index.js`**

把 `app.listen(...)` 改为先取 `server` 句柄，再在其上挂 `WebSocketServer`；并加 debug-push 路由。替换文件末尾与依赖区：

```javascript
require('dotenv').config();
const express = require('express');
const { WebSocketServer } = require('ws');

const app = express();
const PORT = process.env.PORT || 3000;

app.use(express.json());

const syncRouter = require('./routes/sync');
app.use('/api/sync', syncRouter);

const { register, unregister } = require('./services/wsHub');
const { runRulesMode, runLLMMode, sendPush } = require('./services/push');

// 调试用：手动触发一次推送，免去等 cron（仅 dev 用）
app.post('/api/debug-push', (req, res) => {
  const { device_token, title, body } = req.body || {};
  if (!device_token) return res.status(400).json({ error: 'device_token required' });
  const result = sendPush(device_token, {
    title: title || '测试提醒',
    body: body || '这是一条调试推送',
  });
  res.json(result);
});

const cron = require('node-cron');
cron.schedule('*/30 * * * *', async () => {
  console.log('[cron] 推送扫描开始');
  const store = syncRouter.getStore();
  const rulesCount = await runRulesMode(store);
  const llmCount = await runLLMMode(store);
  console.log(`[cron] 完成：规则=${rulesCount} LLM=${llmCount}`);
});

app.get('/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

const server = app.listen(PORT, () => {
  console.log(`知行AI 推送服务启动，端口 ${PORT}`);
});

// 同源挂 WebSocket：/ws?token=xxx
const wss = new WebSocketServer({ server, path: '/ws' });
wss.on('connection', (ws, req) => {
  const url = new URL(req.url, 'http://localhost');
  const token = url.searchParams.get('token');
  if (!token) { ws.close(); return; }
  register(token, ws);
  console.log(`[ws] 设备上线: ${token.slice(0, 8)}...`);
  ws.on('close', () => { unregister(token, ws); console.log(`[ws] 设备离线: ${token.slice(0, 8)}...`); });
  ws.on('error', () => unregister(token, ws));
});
```

**Step 2: 安装 `ws` 依赖**

```bash
cd server && npm install ws@^8.18.0
```

**Step 3: 手动验证 WS 连接 + debug-push**

```bash
# 终端1：启动
cd server && node src/index.js

# 终端2：用 wscat 连 WS（需全局装：npm i -g wscat）
wscat -c "ws://localhost:3000/ws?token=test_token"

# 终端3：触发 debug-push
curl -X POST http://localhost:3000/api/debug-push \
  -H "Content-Type: application/json" \
  -d '{"device_token":"test_token","title":"该复盘了","body":"你有个目标快到期"}'
# 预期：终端2 的 wscat 收到 {"type":"push","title":"该复盘了","body":"...","ts":...}
#       终端1 日志 [ws] 设备上线 / [push] delivered
```

**Step 4: 提交**

```bash
git add server/src/index.js server/package.json server/package-lock.json
git commit -m "feat(server): attach WebSocket server and add debug-push route"
```

---

### Task 3: 重写 `push.js` 的 `sendPush` 走 wsHub + 单测

**Files:**
- Modify: `server/src/services/push.js`（`sendPush` 改用 `wsHub.pushToToken`）
- Create: `server/tests/push.test.js`

**Step 1: 写失败测试 `server/tests/push.test.js`**

```javascript
const test = require('node:test');
const assert = require('node:assert');
const push = require('../src/services/push');
const wsHub = require('../src/services/wsHub');

test('sendPush delivers via wsHub and reports count', async () => {
  let captured;
  wsHub.pushToToken = (token, payload) => { captured = { token, payload }; return 2; };
  const res = await push.sendPush('devX', { title: '标题', body: '内容' });
  assert.equal(res.delivered, 2);
  assert.equal(captured.token, 'devX');
  assert.equal(captured.payload.type, 'push');
  assert.equal(captured.payload.title, '标题');
  assert.equal(captured.payload.body, '内容');
});
```

**Step 2: 跑测试确认失败**

Run: `cd server && node --test tests/`
Expected: FAIL（`push.sendPush` 仍返回 `{sent:true,method:'console'}`，`delivered` 为 undefined）

**Step 3: 修改 `server/src/services/push.js` 顶部引入 wsHub，并重写 `sendPush`**

在文件顶部 `require` 区加：
```javascript
const wsHub = require('./wsHub');
```

把 `sendPush` 替换为：
```javascript
/**
 * 发送推送通知（站内，经 WebSocket 真下发）
 *
 * 通过 wsHub.pushToToken 把提醒推到该设备当前活跃的 WS 连接。
 * 无活跃连接时 delivered=0（v1 不做补发队列，断线期间推送丢弃）。
 */
async function sendPush(deviceToken, notification) {
  const delivered = wsHub.pushToToken(deviceToken, {
    type: 'push',
    title: notification.title,
    body: notification.body,
    ts: Date.now(),
  });
  console.log(`[push] → ${deviceToken.slice(0, 8)}... delivered=${delivered}`);
  return { delivered, method: 'ws' };
}
```

`runRulesMode` / `runLLMMode` 不变（它们已调用 `sendPush(token, {...})`）。

**Step 4: 跑测试确认通过**

Run: `cd server && node --test tests/`
Expected: PASS（含 Task1 共 4 passed）

**Step 5: 提交**

```bash
git add server/src/services/push.js server/tests/push.test.js
git commit -m "feat(server): route sendPush through wsHub for real in-app delivery"
```

---

### Task 4: 客户端抽取 `serverBaseUrl` 常量 + 重构 `SyncService`

**Files:**
- Modify: `lib/core/constants.dart`（加 `serverBaseUrl` / `serverWsUrl`）
- Modify: `lib/core/services/sync_service.dart:52-56`（baseUrl 改用常量）

**Step 1: 在 `lib/core/constants.dart` 的 `AppConstants` 中加**

```dart
/// 服务端基地址（HTTP 与 WS 共用）。
/// 默认 localhost，适合 iOS 模拟器；真机联调改为 Mac 局域网 IP（如 http://192.168.x.x:3000）。
static const String serverBaseUrl = 'http://localhost:3000';

/// WS 地址：把 http:// 换成 ws://
static String get serverWsUrl =>
    serverBaseUrl.replaceFirst('http://', 'ws://').replaceFirst('https://', 'wss://');
```

**Step 2: 修改 `lib/core/services/sync_service.dart`**

顶部加 import：
```dart
import 'package:zhixing_ai/core/constants.dart';
```

把 `Dio` 的 `baseUrl` 写死行改为：
```dart
final Dio _dio = Dio(BaseOptions(
  baseUrl: AppConstants.serverBaseUrl,
  connectTimeout: const Duration(seconds: 5),
  receiveTimeout: const Duration(seconds: 5),
));
```

**Step 3: 跑分析**

Run: `flutter analyze lib/core/constants.dart lib/core/services/sync_service.dart`
Expected: 0 error

**Step 4: 提交**

```bash
git add lib/core/constants.dart lib/core/services/sync_service.dart
git commit -m "refactor(flutter): extract serverBaseUrl constant, share between HTTP and WS"
```

---

### Task 5: 客户端 `PushSocketService` + 单测

**Files:**
- Create: `lib/core/services/push_socket_service.dart`
- Create: `test/push_socket_service_test.dart`
- Modify: `pubspec.yaml`（加 `web_socket_channel` 依赖）

**Step 1: 加依赖**

在 `pubspec.yaml` 的 `dependencies` 加：
```yaml
  web_socket_channel: ^3.0.0
```
Run: `flutter pub get`

**Step 2: 写失败测试 `test/push_socket_service_test.dart`**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:zhixing_ai/core/services/push_socket_service.dart';

void main() {
  test('parsePushMessage parses valid push', () {
    final m = parsePushMessage('{"type":"push","title":"t","body":"b"}');
    expect(m, isNotNull);
    expect(m!.title, 't');
    expect(m!.body, 'b');
  });

  test('parsePushMessage returns null for non-push type', () {
    expect(parsePushMessage('{"type":"other"}'), isNull);
  });

  test('parsePushMessage returns null for invalid json', () {
    expect(parsePushMessage('not json'), isNull);
  });

  test('buildWsUrl embeds token', () {
    expect(buildWsUrl('abc'), endsWith('/ws?token=abc'));
  });
}
```

**Step 3: 跑测试确认失败**

Run: `flutter test test/push_socket_service_test.dart`
Expected: FAIL（找不到 `parsePushMessage` / `buildWsUrl`）

**Step 4: 最小实现 `lib/core/services/push_socket_service.dart`**

```dart
import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/services/push_service.dart';

/// 解析服务端推送消息（纯函数，便于单测）
PushMessage? parsePushMessage(String raw) {
  try {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    if (map['type'] != 'push') return null;
    return PushMessage(map['title'] ?? '', map['body'] ?? '');
  } catch (_) {
    return null;
  }
}

/// 构建 WS 连接地址（纯函数，便于单测）
String buildWsUrl(String token) => '${AppConstants.serverWsUrl}/ws?token=$token';

class PushMessage {
  final String title;
  final String body;
  PushMessage(this.title, this.body);
}

typedef PushHandler = void Function(String title, String body);

/// 客户端 WS 连接服务：连接 / 监听 / 重连 / 派发
class PushSocketService {
  static final PushSocketService instance = PushSocketService._();
  PushSocketService._();

  WebSocketChannel? _channel;
  final List<PushHandler> _handlers = [];
  Timer? _reconnectTimer;
  bool _disposed = false;

  void addHandler(PushHandler h) => _handlers.add(h);

  Future<void> connect() async {
    if (_disposed) return;
    final token = await PushService().getToken();
    if (token == null) return;
    try {
      _channel = WebSocketChannel.connect(Uri.parse(buildWsUrl(token)));
      _channel!.stream.listen(
        _onMessage,
        onDone: (_) => _onDisconnect(),
        onError: (_) => _onDisconnect(),
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic message) {
    final msg = parsePushMessage(message.toString());
    if (msg == null) return;
    for (final h in _handlers) h(msg.title, msg.body);
  }

  void _onDisconnect() {
    _channel = null;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), connect);
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _channel?.sink.close();
  }
}
```

**Step 5: 跑测试确认通过**

Run: `flutter test test/push_socket_service_test.dart`
Expected: PASS（4 passed）

**Step 6: 提交**

```bash
git add lib/core/services/push_socket_service.dart test/push_socket_service_test.dart pubspec.yaml pubspec.lock
git commit -m "feat(flutter): add PushSocketService with WS connect/listen/reconnect"
```

---

### Task 6: 接入 `main.dart` 并弹应用内横幅

**Files:**
- Modify: `lib/main.dart`（全局 NavigatorKey、启动连接、注册横幅 handler）

**Step 1: 修改 `lib/main.dart`**

在 `main()` 顶部（WidgetsFlutterBinding 之后）定义并暴露全局 key：
```dart
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
```
（`navigatorKey` 需声明在 `main()` 之外或为 static；按现有 main 结构放在文件顶层。）

在 `MaterialApp` 上加 `navigatorKey: navigatorKey`。

在 `SettingsRepository.instance.initialize()` 之后启动连接并注册横幅：
```dart
import 'package:zhixing_ai/core/services/push_socket_service.dart';

await SettingsRepository.instance.initialize();

PushSocketService.instance.connect();
PushSocketService.instance.addHandler((title, body) {
  final context = navigatorKey.currentContext;
  if (context != null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
            if (body.isNotEmpty) Text(body),
          ],
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }
});
```

**Step 2: 跑分析**

Run: `flutter analyze lib/main.dart`
Expected: 0 error

**Step 3: 提交**

```bash
git add lib/main.dart
git commit -m "feat(flutter): wire PushSocketService and show in-app banner on push"
```

---

### Task 7: 端到端验证 + 收尾

**Step 1: 服务端单测全绿**

Run: `cd server && node --test tests/`
Expected: PASS（4 passed）

**Step 2: 客户端单测全绿**

Run: `flutter test test/push_socket_service_test.dart`
Expected: PASS

**Step 3: 全量分析**

Run: `flutter analyze lib/`
Expected: 0 error / 0 warning（info 级 avoid_print 可接受）

**Step 4: 端到端真机/模拟器验证（查产物，不查文本）**

```bash
# 1. 启动服务端
cd server && node src/index.js

# 2. 模拟器跑 App（serverBaseUrl=localhost），进入 Dashboard 触发 /api/sync
#    → 服务端日志应打 [sync]

# 3. 另开终端连 WS 模拟「第二个客户端」确认协议（可选）：
wscat -c "ws://localhost:3000/ws?token=test_token"

# 4. 触发推送
curl -X POST http://localhost:3000/api/debug-push \
  -H "Content-Type: application/json" \
  -d '{"device_token":"<App 实际 token>","title":"该复盘了","body":"你有个目标快到期"}'
#    → App 内应真弹出 SnackBar 横幅（这是「联动」真生效的证据）
```

> 拿 App 实际 token：服务端 `/api/sync` 日志里 `[sync] device=xxxx...` 即为该设备 token；或临时在 `PushSocketService.connect` 打印 token。

**Step 5: 最终提交（如本步有改动）**

```bash
git add -A
git commit -m "chore: finalize in-app push linkage (server WS + client banner)"
```

---

## 执行顺序

Task 1 → 2 → 3（服务端，可独立跑测试）→ Task 4 → 5 → 6（客户端）→ Task 7（端到端）。

服务端三步与客户端三步可分别独立完成，端到端验证（Task 7）必须等两侧就绪。

## 验证标准

- 每个 task：`node --test` / `flutter test` 对应用例 PASS；`flutter analyze` 零 error。
- 最终「联动」以**模拟器真弹横幅 + 服务端日志 `delivered>0`** 为通过证据（呼应「查产物不查文本」纪律）。

## 明确不做（v1 外）

- 历史消息列表、断线补发队列、APNs/FCM 系统推送、设备鉴权（见设计文档 §9）。
