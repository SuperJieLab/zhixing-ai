# 苏格拉底 AI — 需求目标拆解

> 从 MVP 方案逐项展开为「目标 → 产出 → 验收标准 → 决策点」。
> 每天做完后对着验收标准自查，全部通过才算完成。

---

## 总览

| Day | 阶段 | 核心目标 | 产出物 |
|:--:|------|------|------|
| 1 | 工程搭建 | App 可跑，话题选择页 + 对话页 UI 完整 | 2 页 UI + 路由 + 状态管理骨架 |
| 2 | 端侧推理 | Dart→C++→CoreML 链路跑通 | 模型加载 + 首次推理输出 |
| 3 | 对话引擎 | AI 连续追问 5+ 轮不跑偏 | Prompt 模板 + 追问策略 + 上下文管理 |
| 4 | 洞察总结 | 对话结束 → 洞察卡片正确渲染 | 总结 Prompt + JSON 解析 + UI 页 |
| 5 | 后端搭建 | Postman 能 CRUD 对话和消息 | Go API + SQLite + 全部端点 |
| 6 | 前后端联调 | 手机聊完 → 后端有数据 → 列表能拉 | Flutter ↔ Go 数据同步完成 |
| 7 | 思维图谱 | 一次对话 → 可交互图谱 | 后端分析引擎 + Flutter 可视化 |
| 8 | 错误覆盖 | 所有错误状态 UI 到位，双端跑通 | 状态矩阵全覆盖 + Android 验证 |
| 9 | 模型下载 | 首次启动自动下载模型到沙盒 | 断点续传 + 进度条 |
| 10 | 收尾 | 仓库可对外展示 | README + Demo 视频 + 截图 |

---

## Day 1 — 工程搭建

### 1.1 Flutter 项目初始化

**目标**：把 `flutter create` 的默认计数器改造成 PRD 定义的页面结构。

**产出物**：
- `lib/` 下的 feature-first 目录结构
- Provider 状态管理层
- 话题选择页完整 UI
- 对话页（含 Mock 对话数据）
- 两页之间 Navigator 跳转

**验收标准**：
- [ ] `flutter run` 在 iOS 模拟器 / Android 模拟器上正常启动
- [ ] 话题选择页展示 5 个话题卡片（图标 + 标题 + 描述）
- [ ] 自定义话题输入框可用
- [ ] 点击话题卡片 → Navigator.push 进对话页
- [ ] 对话页展示 Mock 对话气泡（AI 在左，用户在右）
- [ ] 底部输入框 + 发送按钮可交互（仅 UI，不接推理）
- [ ] 历史列表入口图标可见（可无功能）
- [ ] 代码目录结构清晰，无 `default` / `counter` 残留

**技术决策点**：
| 决策 | 选项 | 推荐 |
|------|------|:--:|
| 状态管理 | Provider / Riverpod / Bloc | Provider（PRD 指定，轻量够用） |
| 路由 | Navigator 1.0 / go_router | Navigator 1.0（页面少，够用） |
| 目录结构 | feature-first / layer-first | feature-first：`features/chat/`, `features/topics/`, `features/insights/` |

**目录结构目标**：
```
lib/
├── main.dart                     # App 入口 + Provider 挂载
├── app.dart                      # MaterialApp + 主题配置
├── core/                         # 通用层
│   ├── theme.dart                # 统一色彩/字体
│   └── constants.dart            # 话题列表等常量
├── features/
│   ├── topics/                   # 话题选择
│   │   ├── topic_selection_page.dart
│   │   ├── widgets/
│   │   │   └── topic_card.dart
│   │   └── providers/
│   │       └── topic_provider.dart
│   ├── chat/                     # 对话
│   │   ├── chat_page.dart
│   │   ├── widgets/
│   │   │   ├── chat_bubble.dart
│   │   │   └── chat_input.dart
│   │   └── providers/
│   │       └── chat_provider.dart
│   ├── insights/                 # 洞察总结
│   │   └── insights_page.dart
│   ├── mindmap/                  # 思维图谱
│   │   └── mindmap_page.dart
│   └── history/                  # 历史列表
│       └── history_page.dart
```

---

## Day 2 — 端侧推理接入

### 2.1 模型加载与首次推理

**目标**：iOS 真机上 Dart → C++ (llama.cpp) → CoreML 链路完整跑通。

**产出物**：
- `dart_llama` 包集成
- 模型文件（Qwen 2.5 1.5B Q4_K_M GGUF）放入 App 沙盒
- Dart 侧 `LlamaInferenceService` 封装类
- 一次硬编码 Prompt 的测试推理

**验收标准**：
- [ ] `dart_llama` pub 依赖无编译错误
- [ ] iOS 真机 debug build 成功
- [ ] 模型文件可被 llama.cpp 正确加载（无 crash、无 OOM）
- [ ] 硬编码 Prompt 输入 → 返回合理的中文文本输出
- [ ] 单次推理延迟 < 5 秒（2048 context）
- [ ] 推理完成后内存可正常释放
- [ ] 后台/锁屏回归后推理引擎状态正常

**技术决策点**：
| 决策 | 选项 | 推荐 |
|------|------|:--:|
| Dart 桥接包 | dart_llama / 手写 dart:ffi | dart_llama，不行再手写 ~200 行 FFI |
| 模型放置 | App Bundle / 首次下载到沙盒 | Day 2 手动放沙盒，Day 9 做自动下载 |
| iOS backend | CoreML (自动) / Metal (手动) | CoreML 自动，llama.cpp 内置支持 |

**风险标注**：⚠️ 中风险 — `dart_llama` 包可能不成熟，备选手写 FFI。

---

## Day 3 — 对话引擎

### 3.1 Prompt 模板实现

**目标**：实现苏格拉底 Prompt 构建器，每次调用输出一个追问。

**产出物**：
- `SocraticPromptBuilder` 类（组装完整 Prompt）
- `QuestionStrategy` 追问策略管理器
- `ConversationContext` 上下文管理器（token 管理 + 截断）

**验收标准**：
- [ ] Prompt 模板包含：角色定义 + 6 条对话规则 + 话题 + 历史 + 最新回答 + 轮次
- [ ] 追问策略按轮次正确切换：1→开场白，2-3→深入，4-6→挑战假设，7+→引导总结
- [ ] 短回答自动触发具体化追问（「能举一个具体例子吗？」）
- [ ] Context 超出 2048 tokens 时自动截断早期消息
- [ ] 推理参数按 PRD 配置：Temp 0.5, Top-p 0.85, Repeat penalty 1.15, Max 128 tokens

### 3.2 多轮对话稳定性

**目标**：选一个话题，AI 连续追问 5+ 轮不跑偏。

**验收标准**：
- [ ] 同一话题下追问不偏离主题（如「职业发展」不会突然问起「你今天吃什么」）
- [ ] 追问基于用户上一条回答深入（不是随机问题）
- [ ] 5 轮后对话仍然连贯
- [ ] 无重复问题（repeat_penalty 生效）
- [ ] 每次推理延迟稳定在 2-4 秒

---

## Day 4 — 洞察总结

### 4.1 总结 Prompt + JSON 输出

**目标**：对话结束时调用总结 Prompt，产出结构化洞察。

**产出物**：
- `SummaryPromptBuilder` 类
- JSON 解析 + 容错逻辑
- 洞察总结页 UI

**验收标准**：
- [ ] 总结 Prompt 正确传入完整对话历史
- [ ] 模型输出为合法 JSON（含 core_insights, underlying_values, contradictions_found, next_topic_suggestion）
- [ ] JSON 解析失败时有兜底纯文本展示（黄色提示条）
- [ ] 洞察卡片正确渲染：核心洞察 × N + 价值观标签 + 矛盾
- [ ] 对话完成动画展示（入场动效）
- [ ] 「查看思维图谱」和「开始新对话」按钮可用

**技术决策点**：
| 决策 | 选项 | 推荐 |
|------|------|:--:|
| JSON 解析容错 | try-catch + 正则提取 / 调大模型重试 | try-catch，1B 模型 JSON 不稳定，容错更重要 |
| 总结调用时机 | 用户点「结束对话」/ 自动 8 轮 | 用户手动触发 + 8 轮自动提示 |

---

## Day 5 — 后端搭建

### 5.1 Go API 服务

**目标**：Postman 能完成对话和消息的完整 CRUD。

**产出物**：
- Go + Gin 项目骨架
- SQLite + GORM 建表 + Migration
- 全部 REST API 端点实现

**验收标准**：

**Conversation CRUD**：
- [ ] `POST /api/v1/conversations` 创建对话（topic, user_id）
- [ ] `GET /api/v1/conversations` 返回用户对话列表（按时间倒序）
- [ ] `GET /api/v1/conversations/:id` 返回单个对话 + 全部消息
- [ ] `DELETE /api/v1/conversations/:id` 删除对话及关联消息

**Message**：
- [ ] `POST /api/v1/conversations/:id/messages` 追加消息（role, content, round_number）
- [ ] 消息按 round_number 正序返回

**Insight**：
- [ ] `POST /api/v1/conversations/:id/summary` 存储洞察总结
- [ ] `GET /api/v1/insights` 返回用户所有洞察

**通用**：
- [ ] 所有端点返回正确的 HTTP 状态码
- [ ] 请求参数校验（必填字段、类型检查）
- [ ] 错误响应格式统一 `{"error": "message"}`
- [ ] CORS 中间件正确配置
- [ ] 项目结构清晰：`cmd/`, `internal/handler/`, `internal/service/`, `internal/model/`

**目录结构目标**：
```
server/
├── cmd/
│   └── server/
│       └── main.go              # 入口
├── internal/
│   ├── config/
│   │   └── config.go            # 配置集中管理
│   ├── handler/                 # HTTP 层
│   │   ├── conversation.go
│   │   ├── message.go
│   │   └── insight.go
│   ├── service/                 # 业务逻辑
│   │   ├── conversation.go
│   │   └── mindmap.go
│   ├── model/                   # 数据模型
│   │   ├── conversation.go
│   │   ├── message.go
│   │   └── insight.go
│   ├── repository/              # 数据库操作
│   │   └── sqlite.go
│   └── middleware/
│       ├── cors.go
│       └── logger.go
├── migrations/
│   └── 001_init.sql
├── go.mod
└── go.sum
```

---

## Day 6 — 前后端联调

### 6.1 Flutter ↔ Go 数据同步

**目标**：手机聊完一次完整对话 → 后端有数据 → 历史列表能拉取展示。

**产出物**：
- Flutter `dio` HTTP client 封装
- 对话创建/消息追加/总结上传 API 调用
- 历史列表页从后端拉取数据

**验收标准**：
- [ ] 选择话题 → 自动 `POST /conversations` 创建对话
- [ ] 每轮用户回答后 → 自动 `POST /messages` 追加
- [ ] 对话结束 → 自动 `POST /summary` 上传洞察
- [ ] 历史列表页 → `GET /conversations` 拉取并渲染卡片卡片
- [ ] 点击历史卡片 → 进入洞察总结页（数据来自后端）
- [ ] 网络不可用时 → 顶部黄色提示条 + 降级本地存储
- [ ] 左滑删除 → `DELETE /conversations/:id`

---

## Day 7 — 思维图谱

### 7.1 后端图谱分析引擎

**目标**：后端分析一次对话，产出可渲染的图谱节点+连线。

**产出物**：
- 对话文本 → 关键词提取 + 关联分析
- dagre 布局计算（节点坐标）
- API 返回结构化图谱数据

**验收标准**：
- [ ] `GET /api/v1/conversations/:id/graph` 返回节点列表 + 连线列表
- [ ] 每个节点包含：id, label, type (topic/insight/value), x, y 坐标
- [ ] 连线包含：source, target
- [ ] 图谱数据至少包含 3+ 节点和连线
- [ ] dagre 布局无节点重叠

### 7.2 Flutter 图谱渲染

**目标**：Flutter 渲染可缩放、平移的交互式思维图谱。

**验收标准**：
- [ ] CustomPainter 正确渲染节点（圆形 + 标签）和连线
- [ ] GestureDetector 支持双指缩放 + 单指平移
- [ ] 点击节点高亮 + 显示详情
- [ ] 图谱首次加载有入场动画（节点逐个出现）

**技术决策点**：
| 决策 | 选项 | 推荐 |
|------|------|:--:|
| 图谱分析 | LLM 大模型 / 规则引擎 | MVP 用规则引擎（关键词提取 + 简单关联），v1.1 升级 LLM |
| dagre | Go 实现 / Python 脚本调用 | Go 实现（避免多语言依赖） |

**MVP 降级方案**：如果 dagre Go 实现太耗时，先用简单力导向布局手动指定坐标，保证视觉可交互。

---

## Day 8 — 错误覆盖 + 双端验证

### 8.1 状态矩阵全覆盖

**目标**：PRD 定义的所有状态都有对应的 UI 表现。

**验收标准**：

| 状态 | UI 表现 | 验收 |
|------|------|:--:|
| 模型加载中 | 启动页全屏进度条「正在准备 AI 思考引擎(~1.2GB)」 | [ ] |
| 模型加载失败 | 红色错误页 + 重试按钮 | [ ] |
| 等待用户输入 | 输入框可用，光标闪烁 | [ ] |
| AI 思考中 | 输入框禁用，三点跳动动画 | [ ] |
| 对话正常 | 气泡正常展示 | [ ] |
| 网络不可用 | 顶栏黄色提示「离线模式：数据暂存本地」 | [ ] |
| 洞察生成中 | 总结页 loading 动画 | [ ] |
| JSON 解析失败 | 黄色提示 + 兜底纯文本展示 | [ ] |

### 8.2 边界 Case

- [ ] 空话题输入 → 禁用发送按钮
- [ ] 超长回答（> 500 字）→ 正常截断不崩溃
- [ ] 网络断连中对话 → 本地继续，网络恢复后同步
- [ ] 模型推理 crash → 自动重新加载模型 + 提示用户
- [ ] 快速连续发送 → 排队处理，不丢消息

### 8.3 Android 双端验证

- [ ] Android 模拟器/真机正常启动
- [ ] Android NNAPI 推理加速生效
- [ ] 无 iOS 专属 API 调用导致的 crash
- [ ] 屏幕尺寸适配（小屏 4.7" → 大屏 6.7"）

---

## Day 9 — 模型下载

### 9.1 断点续传下载

**目标**：用户首次启动 App，自动从 HuggingFace 下载 Qwen 1.5B 到沙盒。

**产出物**：
- `dio` 断点续传实现
- 下载进度 Provider → UI 进度条
- 下载完成自动触发模型加载

**验收标准**：
- [ ] HuggingFace 直链正常可访问
- [ ] 下载进度条实时更新百分比 + 速度
- [ ] 网络中断 → 恢复后从断点继续（HTTP Range）
- [ ] 下载完成 → 自动触发 llama.cpp 模型加载
- [ ] 已下载完成 → 下次启动跳过下载
- [ ] 下载失败 → 重试按钮 + 手动选择模型文件
- [ ] 存储空间不足 → 友好提示

**技术决策点**：
| 决策 | 选项 | 推荐 |
|------|------|:--:|
| 模型托管 | HuggingFace / 自建 CDN | HuggingFace 直链 + Range 支持 |
| 存储位置 | `getApplicationDocumentsDirectory()` | Flutter path_provider |

---

## Day 10 — 收尾

### 10.1 对外展示就绪

**目标**：GitHub 仓库可对外展示，含架构图 + 截图 + 简历描述。

**验收标准**：
- [ ] README 包含：一句话描述 + 架构图 + 技术栈 + 快速开始 + 截图（6 页面 + 错误状态）+ 简历话术
- [ ] 2 分钟 Demo 视频录制完成（展示一次完整对话流程）
- [ ] 6 个页面截图：话题选择、对话中、洞察总结、思维图谱、历史列表、错误状态
- [ ] 代码无 debug print / TODO / 注释掉的旧代码
- [ ] 仓库 Push 到 GitHub（public）
- [ ] `pubspec.yaml` 描述/版本号正确

---

## 整体非功能需求

贯穿所有 Day 的质量要求：

| 维度 | 目标 | 验证方式 |
|------|------|------|
| 动画帧率 | 所有页面过渡 ≥ 60fps | Flutter DevTools Performance |
| 推理延迟 | 单次追问 < 5s（2048 context） | 实测计时 |
| 内存 | 模型加载后 App 内存 < 500MB（iOS 更严格 < 400MB） | Xcode Instruments / Android Profiler |
| 崩溃率 | 主流程 0 crash | Monkey 测试 1000 次随机操作 |
| 可访问性 | WCAG 2.1 AA — 语义标签、足够对比度 | iOS Accessibility Inspector |

---

## 风险对照表（与每日关联）

| 风险 | 关联 Day | 降级策略 |
|------|:--:|------|
| Qwen 1.5B 追问质量不够 | Day 3 | 加强 Dart 层策略；备选 Qwen 2.5 3B |
| dart_llama 包不成熟 | Day 2 | 手写 dart:ffi ~200 行 |
| 模型 1.2GB 下载太慢 | Day 9 | HuggingFace 直链 + 断点续传 |
| 10 天太紧 | Day 7 | 思维图谱降级为规则引擎 |
| 中文追问重复 | Day 3 | repeat_penalty 1.15 + Prompt 强化 |
| Android 碎片化 | Day 8 | 限定 Android 10+，无 NPU 降级 CPU |
| Go 后端时间不够 | Day 5-7 | 先做最小 API（CRUD），图谱用规则引擎 |
