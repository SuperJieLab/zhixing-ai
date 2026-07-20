/**
 * routes/sync.js — 数据同步路由
 * ================================
 *
 * 【这个文件做什么】
 * 接收 Flutter App 上报的 Dashboard 数据（目标 + 策略），存到内存 Map 中。
 * 服务端不持久化数据——重启即清空，收到数据只用于当期推送决策。
 *
 * 【在架构中的位置】
 *   index.js 挂载本路由 → POST /api/sync
 *   push.js 通过 router.getStore() 读取存储数据来做推送决策
 *
 * 【数据流】
 *   Flutter App                                   本文件
 *   ─────────                                    ──────
 *   DashboardProvider.load() 完成后
 *     → SyncService.syncDashboard()
 *       → POST /api/sync ──────────────────────→ 存入 deviceStore Map
 *           body: {                               key: device_token
 *             device_token                        value: { mode, goals, strategies }
 *             mode: "rules" | "llm"
 *             goals: [...]
 *             strategies: [...]
 *           }
 *
 * 【关键设计】
 *   - 不验证用户身份（MVP，单用户场景）
 *   - 同一 device_token 重复 POST 会覆盖旧数据
 *   - 通过 router.getStore() 暴露数据给 push.js（非标准 Express 模式，但 MVP 够用）
 */

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
