# 知行AI — 服务端推送与 AI 增强实现计划（MVP）

> **For WorkBuddy:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为知行AI 添加服务端推送提醒 + AI 智能推送决策能力，完成 设定→追踪→提醒 的产品闭环。

**Architecture:** 新增 `server/` 目录存放 Node.js + Express 服务端代码（规则推送 + DeepSeek LLM 推送决策），Flutter 端新增 Firebase Cloud Messaging 集成 + 设置页开关 + 数据同步上报。

**Tech Stack:** Node.js + Express + node-cron + DeepSeek API + Firebase Cloud Messaging (Flutter: firebase_messaging + dio)

**前置条件：**
- 设计方案：`docs/PROJECT.md` §十二 服务端推送方案
- Flutter 端已有 dio 依赖（pubspec.yaml），但尚未使用
- 无现有 Firebase 配置

**服务端代码位置：** `server/` 子目录（与 Flutter 工程同级，不混入 lib/）

**MVP 简化：**
- 跳过 Firebase 真实推送（需 Firebase 项目 + APNs 证书，超出 MVP 范围）
- 服务端 FCM 调用用占位函数，后续替换真实凭据即可
- LLM 模式暂时传结构化数据（语义向量延后实现）

---

### Task 1: 服务端项目骨架

**Files:**
- Create: `server/package.json`
- Create: `server/src/index.js`
- Create: `server/.env.example`
- Create: `server/.gitignore`

**Step 1: 初始化 package.json**

```bash
mkdir -p server && cd server && npm init -y
```

```json
{
  "name": "zhixing-ai-server",
  "version": "1.0.0",
  "description": "知行AI 服务端推送服务",
  "main": "src/index.js",
  "scripts": {
    "start": "node src/index.js",
    "dev": "node --watch src/index.js"
  },
  "dependencies": {
    "express": "^4.21.0",
    "node-cron": "^3.0.3",
    "dotenv": "^16.4.5"
  }
}
```

**Step 2: 安装依赖**

```bash
cd server && npm install
```

**Step 3: 创建 .env.example**

```
# DeepSeek API Key（LLM 模式需要）
DEEPSEEK_API_KEY=sk-your-key-here

# 服务端口
PORT=3000

# Firebase Admin SDK JSON 路径（暂不配置，MVP 用占位函数）
# GOOGLE_APPLICATION_CREDENTIALS=./firebase-admin.json
```

**Step 4: 创建 .gitignore**

```
node_modules/
.env
firebase-admin.json
```

**Step 5: 创建 src/index.js（最小启动）**

```javascript
require('dotenv').config();
const express = require('express');

const app = express();
const PORT = process.env.PORT || 3000;

app.use(express.json());

app.get('/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

app.listen(PORT, () => {
  console.log(`知行AI 推送服务启动，端口 ${PORT}`);
});
```

**Step 6: 验证**

```bash
cd server && node src/index.js
# 另一个终端：curl http://localhost:3000/health
# 期望：{"status":"ok","timestamp":"..."}
```

**Step 7: 提交**

```bash
git add server/
git commit -m "feat(server): init Node.js + Express skeleton with health check"
```

---

### Task 2: POST /api/sync 接收端侧数据

**Files:**
- Create: `server/src/routes/sync.js`
- Modify: `server/src/index.js` — 挂载路由

**Step 1: 创建路由文件 `server/src/routes/sync.js`**

```javascript
const express = require('express');
const router = express.Router();

// 内存存储（MVP：不持久化，重启即清空）
// 结构：{ deviceToken: { goals, strategies, mode, updatedAt } }
const deviceStore = new Map();

router.post('/', (req, res) => {
  const { device_token, mode, goals, strategies } = req.body;

  // 基础校验
  if (!device_token) {
    return res.status(400).json({ error: 'device_token is required' });
  }

  deviceStore.set(device_token, {
    mode: mode || 'rules',
    goals: goals || [],
    strategies: strategies || [],
    updatedAt: new Date().toISOString(),
  });

  console.log(`[sync] device=${device_token.slice(0, 8)}... mode=${mode} goals=${goals?.length || 0}`);

  res.json({
    success: true,
    synced_at: new Date().toISOString(),
  });
});

// 供其他模块访问存储数据
router.getStore = () => deviceStore;

module.exports = router;
```

**Step 2: 修改 `server/src/index.js` 挂载路由**

在 `app.use(express.json());` 后添加：

```javascript
const syncRouter = require('./routes/sync');
app.use('/api/sync', syncRouter);
```

**Step 3: 验证**

```bash
curl -X POST http://localhost:3000/api/sync \
  -H "Content-Type: application/json" \
  -d '{"device_token":"test_token_123","mode":"rules","goals":[{"title":"跳槽","deadline":"2026-08-01"}],"strategies":[]}'
# 期望：{"success":true,"synced_at":"..."}
```

**Step 4: 提交**

```bash
git add server/
git commit -m "feat(server): add POST /api/sync endpoint with in-memory store"
```

---

### Task 3: 规则模式推送决策 + 占位推送函数

**Files:**
- Create: `server/src/services/push.js` — 推送决策 + 发送
- Create: `server/src/services/rules-engine.js` — 规则引擎
- Modify: `server/src/index.js` — 挂载 cron 任务

**Step 1: 创建规则引擎 `server/src/services/rules-engine.js`**

```javascript
/**
 * 规则模式推送决策
 *
 * 规则：策略有 deadline 且在未来 3 天内、未完成 → 推送
 */
function shouldPush(goals, strategies) {
  const now = new Date();
  const threeDaysLater = new Date(now.getTime() + 3 * 24 * 60 * 60 * 1000);

  const pendingStrategies = strategies.filter((s) => !s.completed);

  if (pendingStrategies.length === 0) return null;

  // 检查是否有即将到期的目标
  for (const goal of goals) {
    if (!goal.deadline) continue;

    const deadline = new Date(goal.deadline);
    if (deadline > now && deadline <= threeDaysLater && goal.status === 'active') {
      const daysLeft = Math.ceil((deadline - now) / (1000 * 60 * 60 * 24));
      return {
        shouldPush: true,
        title: '目标即将到期',
        body: `「${goal.title}」还有 ${daysLeft} 天到期，当前有 ${pendingStrategies.length} 条策略待完成`,
        data: { type: 'goal_reminder', goal_title: goal.title },
      };
    }
  }

  // 有未完成策略但未设截止日期 → 每日提醒一次
  const lastSyncToday = strategies.some((s) => {
    if (!s.created_at) return false;
    const created = new Date(s.created_at);
    return created.toDateString() === now.toDateString();
  });

  if (pendingStrategies.length > 0 && !lastSyncToday) {
    return {
      shouldPush: true,
      title: '今日待办',
      body: `你有 ${pendingStrategies.length} 条策略待完成，打开 App 看看进展吧`,
      data: { type: 'daily_reminder' },
    };
  }

  return null;
}

module.exports = { shouldPush };
```

**Step 2: 创建推送服务 `server/src/services/push.js`**

```javascript
const { shouldPush: rulesShouldPush } = require('./rules-engine');

/**
 * 发送推送通知（占位函数）
 *
 * MVP 阶段用 console.log 代替真实 FCM 调用。
 * 后续替换为：
 *   const admin = require('firebase-admin');
 *   await admin.messaging().send({ token, notification: { title, body }, data });
 */
async function sendPush(deviceToken, notification) {
  console.log(`[push] → ${deviceToken.slice(0, 8)}...`);
  console.log(`[push]   title: ${notification.title}`);
  console.log(`[push]   body: ${notification.body}`);
  // TODO: 替换为真实 Firebase Admin SDK 调用
  return { sent: true, method: 'console' };
}

/**
 * 规则模式：扫描所有设备，决策 + 推送
 */
async function runRulesMode(deviceStore) {
  let pushed = 0;
  for (const [token, data] of deviceStore.entries()) {
    if (data.mode !== 'rules') continue;
    const decision = rulesShouldPush(data.goals, data.strategies);
    if (decision?.shouldPush) {
      await sendPush(token, {
        title: decision.title,
        body: decision.body,
        data: decision.data || {},
      });
      pushed++;
    }
  }
  return pushed;
}

module.exports = { sendPush, runRulesMode };
```

**Step 3: 修改 `server/src/index.js` 挂载 cron**

在 `app.use('/api/sync', syncRouter);` 后添加：

```javascript
const cron = require('node-cron');
const { runRulesMode } = require('./services/push');

// 每 30 分钟扫描一次
cron.schedule('*/30 * * * *', async () => {
  console.log('[cron] 规则模式扫描开始');
  const store = syncRouter.getStore();
  const count = await runRulesMode(store);
  console.log(`[cron] 规则模式推送了 ${count} 个设备`);
});
```

**Step 4: 验证**

```bash
# 启动服务
cd server && node src/index.js

# 上传即将到期的数据
curl -X POST http://localhost:3000/api/sync \
  -H "Content-Type: application/json" \
  -d '{"device_token":"test_123","mode":"rules","goals":[{"title":"跳槽","deadline":"2026-07-22","status":"active"}],"strategies":[{"description":"更新简历","completed":false}]}'

# 观察日志输出：应该看到 [cron] 扫描后输出推送内容
```

**Step 5: 提交**

```bash
git add server/
git commit -m "feat(server): add rules-based push engine with cron scheduler"
```

---

### Task 4: LLM 模式推送决策（DeepSeek API）

**Files:**
- Create: `server/src/services/llm-engine.js`
- Modify: `server/src/services/push.js` — 添加 runLLMMode
- Modify: `server/src/index.js` — cron 中调用 LLM 模式

**Step 1: 创建 LLM 引擎 `server/src/services/llm-engine.js`**

```javascript
/**
 * 调用 DeepSeek API 做推送决策
 *
 * API 文档：https://platform.deepseek.com/api-docs
 */
async function analyzePushDecision(goals, strategies) {
  const apiKey = process.env.DEEPSEEK_API_KEY;

  // 无 API Key → 回退规则模式
  if (!apiKey || apiKey === 'sk-your-key-here') {
    console.log('[llm] 无 DeepSeek API Key，跳过 LLM 决策');
    return null;
  }

  const goalsSummary = goals
    .map((g) => `- [${g.status}] ${g.title}${g.deadline ? ` (截止: ${g.deadline})` : ''}`)
    .join('\n');

  const strategiesSummary = strategies
    .filter((s) => !s.completed)
    .map((s) => `- ${s.description}`)
    .join('\n');

  const prompt = `你是一个个人目标管理助手的推送决策模块。

用户当前的目标和策略：

目标：
${goalsSummary || '(无)'}

未完成策略：
${strategiesSummary || '(无)'}

请判断现在是否需要向用户发送推送提醒。

规则：
- 如果有即将到期的目标（未来3天内）或长期未推进的策略，应该推送
- 推送内容应简洁、具体、有行动号召力，不超过50字
- 如果所有目标都在正常推进中，可以不推送

请只返回 JSON，格式：
{"should_push": true/false, "title": "推送标题", "body": "推送内容"}`;

  try {
    const response = await fetch('https://api.deepseek.com/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model: 'deepseek-chat',
        messages: [
          { role: 'system', content: '你是一个推送决策助手，只返回 JSON。' },
          { role: 'user', content: prompt },
        ],
        temperature: 0.3,
        max_tokens: 200,
      }),
    });

    const data = await response.json();
    const content = data.choices?.[0]?.message?.content || '';

    // 解析 JSON（去除可能的 markdown 代码块）
    const jsonStr = content.replace(/```json\n?/g, '').replace(/```/g, '').trim();
    const result = JSON.parse(jsonStr);

    console.log(`[llm] decision: should_push=${result.should_push}`);
    return result;
  } catch (err) {
    console.error('[llm] DeepSeek API 调用失败:', err.message);
    return null; // 失败时返回 null，不推送
  }
}

module.exports = { analyzePushDecision };
```

**Step 2: 修改 `server/src/services/push.js`**

添加 LLM 模式：

```javascript
const { analyzePushDecision } = require('./llm-engine');

/**
 * LLM 模式：对每个设备调用 DeepSeek 决策
 */
async function runLLMMode(deviceStore) {
  let pushed = 0;
  for (const [token, data] of deviceStore.entries()) {
    if (data.mode !== 'llm') continue;
    const decision = await analyzePushDecision(data.goals, data.strategies);
    if (decision?.should_push) {
      await sendPush(token, {
        title: decision.title || '知行AI 提醒',
        body: decision.body,
        data: { type: 'llm_reminder' },
      });
      pushed++;
    }
  }
  return pushed;
}

module.exports = { sendPush, runRulesMode, runLLMMode };
```

**Step 3: 修改 `server/src/index.js` cron 任务**

```javascript
const { runRulesMode, runLLMMode } = require('./services/push');

cron.schedule('*/30 * * * *', async () => {
  console.log('[cron] 推送扫描开始');
  const store = syncRouter.getStore();
  const rulesCount = await runRulesMode(store);
  const llmCount = await runLLMMode(store);
  console.log(`[cron] 完成：规则=${rulesCount} LLM=${llmCount}`);
});
```

**Step 4: 验证（无 API Key 时 LLM 模式应优雅跳过）**

```bash
curl -X POST http://localhost:3000/api/sync \
  -H "Content-Type: application/json" \
  -d '{"device_token":"test_456","mode":"llm","goals":[{"title":"学英语","deadline":"2026-08-15","status":"active"}],"strategies":[{"description":"每天背50个单词","completed":false}]}'

# 观察日志：[llm] 无 DeepSeek API Key，跳过 LLM 决策
```

（如果有 API Key，在 `.env` 中配置后重启服务即可验证完整链路）

**Step 5: 提交**

```bash
git add server/
git commit -m "feat(server): add LLM-based push decision via DeepSeek API"
```

---

### Task 5: Flutter 端 firebase_messaging 集成

**Files:**
- Modify: `pubspec.yaml` — 添加 firebase_messaging 依赖
- Modify: `lib/main.dart` — 初始化 Firebase
- Create: `lib/core/services/push_service.dart` — 推送服务封装

**Step 1: 添加依赖**

在 `pubspec.yaml` 的 dependencies 中添加：

```yaml
  firebase_core: ^3.8.0
  firebase_messaging: ^15.1.5
```

然后运行 `flutter pub get`。

**Step 2: 创建推送服务 `lib/core/services/push_service.dart`**

```dart
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:zhixing_ai/core/logger.dart';

/// 推送服务
///
/// 管理 FCM token 获取、推送权限请求、消息处理。
/// MVP 阶段 Firebase 项目未配置时降级为 Mock 模式。
class PushService {
  static final PushService _instance = PushService._();
  factory PushService() => _instance;
  PushService._();

  String? _token;
  String? get token => _token;

  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    try {
      final messaging = FirebaseMessaging.instance;

      // 请求通知权限（iOS 需要）
      await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      // 获取 FCM token
      _token = await messaging.getToken();
      AppLogger.i('FCM token: ${_token?.substring(0, 12)}...');

      // 监听 token 刷新
      messaging.onTokenRefresh.listen((newToken) {
        _token = newToken;
        AppLogger.i('FCM token refreshed');
      });
    } catch (e) {
      // Firebase 未配置时降级为 Mock token
      _token = 'mock_token_${DateTime.now().millisecondsSinceEpoch}';
      AppLogger.i('FCM 不可用，使用 Mock token: $_token');
    }
  }

  /// 获取当前设备推送 token（首次调用时自动初始化）
  Future<String?> getToken() async {
    if (_token == null) await initialize();
    return _token;
  }
}
```

**Step 3: 修改 `lib/main.dart` 初始化 Firebase**

在 `WidgetsFlutterBinding.ensureInitialized();` 之后添加：

```dart
import 'package:firebase_core/firebase_core.dart';

// 初始化 Firebase（未配置时 catch 异常，不影响 App 运行）
try {
  await Firebase.initializeApp();
} catch (e) {
  // Firebase 未配置时忽略
}
```

以及初始化 PushService：

```dart
// 触发推送 token 获取（异步，不阻塞启动）
PushService().initialize();
```

**Step 4: 提交**

```bash
git add pubspec.yaml pubspec.lock lib/main.dart lib/core/services/
git commit -m "feat(flutter): add Firebase Cloud Messaging integration with mock fallback"
```

---

### Task 6: Flutter 端数据同步上报

**Files:**
- Create: `lib/core/services/sync_service.dart` — HTTP 同步服务
- Modify: `lib/features/dashboard/providers/dashboard_provider.dart` — 数据变更后触发同步

**Step 1: 创建同步服务 `lib/core/services/sync_service.dart`**

```dart
import 'package:dio/dio.dart';
import 'package:zhixing_ai/core/logger.dart';
import 'package:zhixing_ai/core/models/dashboard_models.dart';
import 'package:zhixing_ai/core/services/push_service.dart';

/// 数据同步服务
///
/// 将 Dashboard 数据上报到服务端用于推送决策。
/// 服务端地址通过环境变量或硬编码配置（MVP 用 localhost）。
class SyncService {
  static final SyncService _instance = SyncService._();
  factory SyncService() => SyncService._();
  SyncService._();

  final Dio _dio = Dio(BaseOptions(
    baseUrl: 'http://localhost:3000',
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 5),
  ));

  bool _aiOptimized = false;

  bool get aiOptimized => _aiOptimized;
  set aiOptimized(bool value) => _aiOptimized = value;

  /// 同步 Dashboard 数据到服务端
  Future<void> syncDashboard({
    required List<Goal> goals,
    required List<Strategy> strategies,
  }) async {
    final token = await PushService().getToken();
    if (token == null) return;

    try {
      await _dio.post('/api/sync', data: {
        'device_token': token,
        'mode': _aiOptimized ? 'llm' : 'rules',
        'goals': goals.map((g) => {
          'title': g.title,
          'category': g.category.name,
          'status': g.status.name,
          'deadline': g.deadline,
          'priority': g.priority,
        }).toList(),
        'strategies': strategies.map((s) => {
          'description': s.description,
          'goal_id': s.goalId,
          'completed': s.completed,
        }).toList(),
      });
      AppLogger.i('数据同步完成');
    } catch (e) {
      AppLogger.i('数据同步失败（服务端可能未启动）: $e');
    }
  }
}
```

**Step 2: 修改 DashboardProvider 触发同步**

在 `lib/features/dashboard/providers/dashboard_provider.dart` 中：

文件顶部添加 import：
```dart
import 'package:zhixing_ai/core/services/sync_service.dart';
```

在 `load()` 方法末尾（`_notify()` 之前或之后），添加同步调用：

```dart
// load() 方法中，在数据加载完成后触发同步
_syncToServer();
```

添加私有方法：
```dart
void _syncToServer() {
  SyncService().syncDashboard(
    goals: _state.goals,
    strategies: _state.strategies,
  );
}
```

同样在 `toggleGoalStatus` 和 `toggleStrategy` 方法的 `load()` 调用之后会自然触发同步（因为 load 后会调用 `_syncToServer`）。

**Step 3: 验证**

启动服务端后，在 App 中进入 Dashboard 页面，观察服务端日志应有 `[sync]` 输出。

**Step 4: 提交**

```bash
git add lib/core/services/ lib/features/dashboard/providers/
git commit -m "feat(flutter): add Dashboard data sync to server via POST /api/sync"
```

---

### Task 7: Flutter 端设置页「AI 优化推送」开关

**Files:**
- Modify: `lib/features/dashboard/dashboard_page.dart` — 在设置入口附近新增开关入口

（MVP 使用 DashboardPage AppBar 的 settings 按钮附近添加一个简单的开关对话框，不单独创建设置页）

**Step 1: 修改 DashboardPage，在 AppBar actions 中添加开关入口**

在 `lib/features/dashboard/dashboard_page.dart` 的 AppBar actions 最前面添加：

```dart
import 'package:zhixing_ai/core/services/sync_service.dart';

// 在 _DashboardPageState 中添加方法：
void _showPushSettings() {
  final syncService = SyncService();
  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        title: const Text('推送设置'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              title: const Text('AI 优化推送'),
              subtitle: const Text('开启后，服务端使用 AI 分析你的目标数据，生成更智能的推送提醒。对话原文不会被上传。'),
              value: syncService.aiOptimized,
              onChanged: (val) {
                setDialogState(() {
                  syncService.aiOptimized = val;
                });
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('确定'),
          ),
        ],
      ),
    ),
  );
}
```

然后在 AppBar actions 中，在 settings 图标前面加一个推送设置图标：

```dart
actions: [
  IconButton(
    icon: const Icon(Icons.notifications_outlined),
    onPressed: _showPushSettings,
    tooltip: '推送设置',
  ),
  IconButton(
    icon: const Icon(Icons.settings),
    onPressed: _openModelManager,
    tooltip: '模型管理',
  ),
  // ...
],
```

首次开启 AI 优化时弹出隐私说明（在 `onChanged` 回调中检测从 false→true 时触发）：

```dart
onChanged: (val) {
  if (val && !syncService.aiOptimized) {
    // 首次开启时显示隐私说明
    showDialog(
      context: ctx,
      builder: (c) => AlertDialog(
        title: const Text('AI 优化推送说明'),
        content: const Text('开启后将上传目标标题、分类、截止日期和策略描述到服务端，用于 AI 分析推送时机。'
            '对话原文不会被上传。数据在服务端处理完成后即丢弃，不会持久化存储。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              setDialogState(() {
                syncService.aiOptimized = true;
              });
              Navigator.pop(c);
            },
            child: const Text('同意并开启'),
          ),
        ],
      ),
    );
    return;
  }
  setDialogState(() {
    syncService.aiOptimized = val;
  });
},
```

**Step 2: 验证**

在 App 中点击推送设置图标 → 应弹出开关对话框 → 开启 AI 优化 → 应弹出隐私说明 → 确认后开关状态保存。

**Step 3: 提交**

```bash
git add lib/features/dashboard/dashboard_page.dart
git commit -m "feat(flutter): add AI-optimized push toggle in Dashboard settings"
```

---

### Task 8: 端到端验证 + 清理

**Step 1: 完整流程验证**

```bash
# 1. 启动服务端
cd server && node src/index.js

# 2. 在 App 中进入 Dashboard（触发数据同步）
#    → 观察服务端日志 [sync] 输出

# 3. 打开推送设置 → 开启 AI 优化
#    → 再次进入 Dashboard（触发新的同步，mode=llm）

# 4. 手动触发 cron（修改 cron 表达式为 '* * * * *' 每1分钟触发）
#    → 观察服务端日志 [cron] 和 [push] 输出

# 5. 关闭 AI 优化 → 验证 mode=rules 同步
```

**Step 2: 恢复 cron 为 30 分钟**

**Step 3: flutter analyze 验证**

```bash
flutter analyze lib/
```
**期望：** 0 error, 0 warning（info 级别的 avoid_print 可接受）

**Step 4: 最终提交**

```bash
git add -A
git commit -m "chore: finalize server push MVP implementation"
```

---

## 执行顺序

Task 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8

服务器代码（Task 1-4）和 Flutter 代码（Task 5-7）可并行开发，但端到端验证（Task 8）必须等两边都完成。

## 验证标准

每个 task 完成后：
1. 命令验证（curl / 日志输出 符合预期）
2. `flutter analyze lib/` — 零 error/warning（info 可接受）
3. 代码符合项目分层规范
