# 2026-07-09 总结

## 完成

### 思维图谱修复（上午）
- 思维图谱手势全面修复（点击/拖拽/平移/缩放/坐标系统）
- 布局四角堆叠问题根治（力导向 → 辐射分布 + 微力）
- 上下文窗口扩大到 4096，maxTokens 扩大到 3072
- LLM 上下文溢出修复
- 选中态文字消失修复

### Day 7 错误覆盖（下午）
- Chat 错误链路：模型加载失败 UI + 推理失败 SnackBar + 重试
- History 错误链路：DB 失败 UI + 重试
- 边界 case：空话题校验 + 3000 字回答限制
- 补充 3 个测试文件（dart analyze 通过）
- SnackBar 全局防抖（`SnackBarThrottle`, 500ms throttle）
- 分层违规修复：InsightsPage → InsightProvider → MindMapService

## 关键教训

**力导向 / 手势 / 渲染**（见上午笔记）：
- 力导向在多节点互联图上失效（斥力 60+ 倍于引力）
- 硬 clamp 制造速度堆积
- 手势 delta 是单帧增量不是累计
- `CustomPaint(size: Size.infinite)` 的危险性

**错误处理 / 架构**（详见 `错误覆盖-状态矩阵与错误处理.md`）：
- Provider 错误模式：try/catch → `_error` → `notifyListeners()` → Page 渲染错误 UI
- SnackBar 防抖：全局 throttle 优于 `clearSnackBars()`
- 分层违规修复：page 直接 import engine → 抽薄 provider 做接线层
- 端侧 AI 项目测试策略：Dart 逻辑 → mock provider → 真机 e2e，逐层隔离原生依赖

## 提交

- Day 7 error coverage: 4 commits
- SnackBar throttle: 1 commit
- Layering refactor: 1 commit
- 今日合计：6 commits，~550 行新增
