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
| 5 | 端侧持久化 | 会话历史持久化 + 历史列表可用 | sqflite + ConversationProvider + HistoryPage |
| 6 | 思维图谱 | 一次对话 → 可交互图谱 | 端侧 LLM 生成图谱 JSON + CustomPainter 渲染 |
| 7 | 错误覆盖 | 所有错误状态 UI 到位，双端跑通 | 状态矩阵全覆盖 + Android 验证 |
| 8 | 模型下载 | 首次启动自动下载模型到沙盒 | 断点续传 + 进度条 |
| 9 | 收尾 | 仓库可对外展示 | README + Demo 视频 + 截图 + 上架准备 |

### 高阶版（后续迭代 — Resume 加分项）

| 阶段 | 内容 | 定位 |
|------|------|------|
| 后端搭建 | Go + Gin + SQLite REST API | 云端存储基础 |
| 前后端联调 | Flutter 接后端 + 对话同步 + 多端互通 | Web/iPad 回顾台 |
| 云端同步 | 本地优先 + 云端备份 + 冲突解决 | 数据不丢失 |

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
- `llama_cpp_dart` 包集成（实际采用，替代原计划的 `dart_llama`）
- 模型文件（Qwen3.5-2B Q4_K_M GGUF）放入 `assets/models/`
- Dart 侧 `LlamaService` 单例封装
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
- [x] Prompt 模板包含：角色定义 + 6 条对话规则 + 话题 + 历史 + 最新回答 + 轮次
- [x] 追问策略按轮次正确切换：1→探索，2-3→深入，4-6→挑战假设，7+→引导总结（梯度 ProbeStage 枚举）
- [x] 短回答自动触发具体化追问（< 20 字自动升级到深入阶段）
- [x] Context 超出 2048 tokens 时 llama.cpp KV cache 自动截断 + Dart 层 token 估算日志警告
- [x] 推理参数按 PRD 配置：Temp 0.5, Top-p 0.85, Repeat penalty 1.15, Max 128 tokens

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
- [x] 总结 Prompt 正确传入完整对话历史
- [x] 模型输出为合法 JSON（含 core_insights, underlying_values, contradictions_found, next_topic_suggestion）
- [x] JSON 解析失败时有兜底展示（三层回退：直接解析→代码块→正则→原始文本）
- [x] 洞察卡片正确渲染：核心洞察 × N + 价值观标签 + 矛盾
- [x] 对话完成动画展示（fade-in + stagger slide-up 入场动效）
- [x] 「查看思维图谱」（置灰待 Day 7）和「开始新对话」按钮可用

**技术决策点**：
| 决策 | 选项 | 推荐 |
|------|------|:--:|
| JSON 解析容错 | try-catch + 正则提取 / 调大模型重试 | try-catch，1B 模型 JSON 不稳定，容错更重要 |
| 总结调用时机 | 用户点「结束对话」/ 自动 8 轮 | 用户手动触发 + 8 轮自动提示 |

---

## Day 5 — 端侧会话持久化 & 历史管理

### 5.1 数据模型 & 存储层

**目标**：用 sqflite 实现本地会话持久化，聊完的对话不丢失。

**数据模型**：单表 `conversations`，messages 和 insight 以 JSON 列存储。

```
conversations 表
├── id              INTEGER PRIMARY KEY AUTOINCREMENT
├── topic           TEXT NOT NULL              -- 话题标题
├── status          TEXT DEFAULT 'active'      -- active / completed
├── is_favorite     INTEGER DEFAULT 0         -- 0/1
├── messages_json   TEXT                      -- List<ChatMessage> 的 JSON
├── insight_json    TEXT                      -- InsightResult 的 JSON，可为 null
├── created_at      TEXT NOT NULL             -- ISO 8601
└── updated_at      TEXT NOT NULL             -- 最后活跃时间
```

**写入时机**：
| 时机 | 操作 |
|------|------|
| 进入 ChatPage | `INSERT` 创建记录（status='active'） |
| 每轮 AI 追问完成 | `UPDATE messages_json`，整批覆盖 JSON |
| 结束对话 | `UPDATE insight_json + status='completed'` |

**验收标准**：

- [ ] `Conversation` 模型 `toMap()` / `fromMap()` 往返一致（含 messages 和 insight 的 JSON 序列化）
- [ ] `ConversationRepository.initialize()` 在首次运行时建表成功
- [ ] `create()` 插入一条新记录并返回自增 id
- [ ] `updateMessages()` 正确覆盖 messages_json 列
- [ ] `complete()` 写入 insight_json + 更新 status='completed'
- [ ] `listAll()` 按 updated_at 倒序返回所有会话
- [ ] `getById()` 返回完整会话（含解析后的 messages 和 insight）
- [ ] `toggleFavorite()` 切换 is_favorite 0↔1
- [ ] `delete()` 删除指定会话

### 5.2 状态管理 & UI

**组件**：
```
lib/features/history/
├── engine/
│   └── conversation_repository.dart   # sqflite CRUD 封装
├── providers/
│   └── conversation_provider.dart     # 会话列表状态管理
├── widgets/
│   └── conversation_card.dart         # 历史卡片
└── history_page.dart                  # 完整历史列表
```

**ConversationProvider**：
- `loadAll()` — 从 Repository 加载全部会话
- `toggleFavorite(id)` — 切换收藏
- `deleteConversation(id)` — 删除并刷新列表

**ConversationCard**：
- 话题标题 + N 轮对话 + 相对时间
- 有洞察则显示首条摘要（斜体 primary 色），无则显示「尚无洞察总结」
- 右侧收藏星标（可切换）
- 左滑删除（Dismissible + 确认弹窗）

**HistoryPage**：
- 空状态：图标 + 「还没有对话记录，开始第一次探索吧」
- 列表：按 updated_at 倒序展示 ConversationCard
- 点击卡片 → 如已有洞察则跳转 InsightsPage，否则 SnackBar 提示

**验收标准**：

- [ ] ConversationProvider 正确从 Repository 加载数据并通知 UI
- [ ] ConversationCard 正确渲染话题、轮次数、相对时间、洞察摘要
- [ ] 收藏星标点击正确切换 is_favorite 并刷新 UI
- [ ] 左滑删除触发确认弹窗，确认后删除并刷新列表
- [ ] 空状态页面正确展示（无对话记录时）
- [ ] 点击有洞察的卡片跳转 InsightsPage
- [ ] 点击无洞察的卡片弹出 SnackBar 提示
- [ ] `main.dart` 中正确初始化 ConversationRepository
- [ ] `app.dart` 中正确注入 ConversationProvider

### 5.3 ChatPage 集成

**目标**：对话过程自动持久化，无需用户手动操作。

**方式**：ChatProvider 添加 `onMessagesChanged` 可选回调，ChatPage 注入回调写入 Repository。

**验收标准**：

- [ ] 进入 ChatPage → 自动创建 conversations 记录（_conversationId 赋值）
- [ ] 每轮 AI 回复完成后 → messages_json 自动更新
- [ ] 结束对话后 → insight_json + status='completed' 写入
- [ ] 退出 App 再进入 → 历史列表能看到刚聊的会话
- [ ] 模型加载失败（_engine null）时跳过持久化

### 5.4 端到端验证

- [ ] `flutter analyze lib/ test/` — 零 error/warning
- [ ] 完整流程：选话题 → 对话 3+ 轮 → 结束 → 返回首页 → 历史列表看到会话 → 点击查看洞察 → 左滑删除成功
- [ ] 退出 App 后再进入，历史记录仍在

**技术决策**：

| 决策 | 选项 | 选择 | 原因 |
|:--|------|:--:|------|
| 端侧存储 | sqflite / drift / Hive | **sqflite** | Flutter 社区最成熟方案，JSON 列存储简单高效 |
| 消息存储粒度 | 逐条 INSERT / JSON 整批 | **JSON 整批** | 无消息检索需求；每批 ~3-5KB；避免高频写入 |
| 会话 ID | 自增 INTEGER / UUID | **自增 INTEGER** | 本地单用户无冲突风险；与后端 AUTOINCREMENT 一致 |
| Repository 实例化 | 单例 static / 依赖注入 | **单例 static** | 当前只有本地 sqflite 一个数据源，单例足够 |
| Provider ↔ Repository | 回调注入 / event bus | **回调注入** | ChatProvider 不需要知道 Repository 存在；测试友好 |

---

### 高阶版：后续迭代规划

> 核心版定位：端侧推理 + 本地持久化，数据不离开设备。以下为 Resume 加分项的进阶路线。

#### 高阶 1：云端同步（后端 + 联调）

**依赖**：无，可独立开始。

**后端搭建验收标准**：
- [ ] `POST /api/v1/conversations` 创建对话
- [ ] `GET /api/v1/conversations` 返回用户对话列表（时间倒序）
- [ ] `GET /api/v1/conversations/:id` 返回单个对话 + 全部消息
- [ ] `DELETE /api/v1/conversations/:id` 删除对话及关联消息
- [ ] `POST /api/v1/conversations/:id/messages` 追加消息
- [ ] `POST /api/v1/conversations/:id/summary` 存储洞察

**前后端联调验收标准**：
- [ ] 对话开始时自动创建 Conversation（本地 + 云端双写）
- [ ] 每轮对话自动追加 Message
- [ ] 历史列表本地优先，后端作为备份
- [ ] 网络不可用时降级本地存储 + 顶栏黄色提示
- [ ] 冲突解决：简单 last-write-wins

#### 高阶 2：Web/iPad 回顾台

**依赖**：高阶 1（需要后端提供数据）。

**验收标准**：
- [ ] Web 端拉取历史对话列表
- [ ] 思维图谱在大屏上展示 + 导出功能
- [ ] iPad 横屏双栏布局（左侧列表 + 右侧详情）

#### 高阶 3：Watch 触发器 + 传感器

**依赖**：
- 每日推送 → 高阶 1（后端推送服务器 APNs/FCM）
- Watch ↔ Phone 蓝牙 + HealthKit → **不依赖后端**，可独立提前做

**验收标准**：
- [ ] HealthKit 心率数据接入对话上下文（本地读取）
- [ ] Watch 端语音回答 → Phone（WatchConnectivity 蓝牙通信）
- [ ] APNs/FCM 每日定时推送问题（需要后端）

---

## Day 6 — 思维图谱

### 6.1 端侧 LLM 生成图谱

**目标**：端侧 LLM 分析一次对话，产出可渲染的图谱节点+连线（纯端侧，无后端）。

**产出物**：
- `GraphService`：复用 InsightService 模式，LLM 将对话全文转为结构化图谱 JSON
- 图谱数据模型：`GraphNode`（label, weight, category）+ `GraphEdge`（from, to, label）
- Dart 侧 force-directed 布局算法

**验收标准**：
- [ ] LLM 输出合法图谱 JSON（节点数组 + 连线数组）
- [ ] 每个节点包含：id, label, type (topic/insight/value/action)
- [ ] 连线包含：source, target, label
- [ ] 图谱数据至少包含 3+ 节点和连线
- [ ] JSON 解析失败时有纯文本兜底

### 6.2 Flutter 图谱渲染

**目标**：Flutter 渲染可缩放、平移的交互式思维图谱。

**验收标准**：
- [ ] CustomPainter 正确渲染节点（圆形 + 标签）和连线
- [ ] 节点大小按权重变化，连线粗细按关联强度变化
- [ ] 手势交互：拖拽节点 / 双指缩放 / 单指平移
- [ ] 点击节点高亮 + 显示详情
- [ ] 图谱首次加载有入场动画（节点逐个出现）

**技术决策点**：
| 决策 | 选项 | 推荐 |
|------|------|:--:|
| 图谱生成 | LLM 端侧 / 规则引擎 | **LLM 端侧**（复用 InsightService 模式，JSON 输出） |
| 布局算法 | force-directed 自实现 / dagre 库 | **force-directed**（无需外部依赖，简单高效） |

---

## Day 7 — 错误覆盖 + 双端验证

### 7.1 状态矩阵全覆盖

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

### 7.2 边界 Case

- [ ] 空话题输入 → 禁用发送按钮
- [ ] 超长回答（> 500 字）→ 正常截断不崩溃
- [ ] 网络断连中对话 → 本地继续，网络恢复后同步
- [ ] 模型推理 crash → 自动重新加载模型 + 提示用户
- [ ] 快速连续发送 → 排队处理，不丢消息

### 7.3 Android 双端验证

- [ ] Android 模拟器/真机正常启动
- [ ] Android NNAPI 推理加速生效
- [ ] 无 iOS 专属 API 调用导致的 crash
- [ ] 屏幕尺寸适配（小屏 4.7" → 大屏 6.7"）

---

## Day 8 — 模型下载

### 8.1 断点续传下载

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

## Day 9 — 收尾

### 9.1 对外展示就绪

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
| 模型 1.2GB 下载太慢 | Day 8 | HuggingFace 直链 + 断点续传 |
| 10 天太紧 | Day 6 | 思维图谱 LLM JSON 模式；后端移至高阶版 |
| 中文追问重复 | Day 3 | repeat_penalty 1.15 + Prompt 强化 |
| Android 碎片化 | Day 8 | 限定 Android 10+，无 NPU 降级 CPU |
| Go 后端时间不够 | 高阶 | 已移至后续迭代；核心版无后端依赖 |
