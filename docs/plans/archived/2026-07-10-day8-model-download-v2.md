# Day 8 — 模型管理 V2 设计方案（讨论稿）

> 非阻塞式设计：用户先进入 App，再决定何时下载模型。

---

## 一、整体交互流程

```
TopicSelectionPage（首页）
│
├── AppBar 右侧：📦 [模型] 按钮 ← NEW
│   └── 点击 → ModelManagePage
│       ├── 模型列表（MVP：1 个模型）
│       │   ┌─────────────────────────────────────┐
│       │   │ Qwen2.5-1.5B     ~1.06GB     [下载] │
│       │   │ 中文苏格拉底对话，端侧推理            │
│       │   └─────────────────────────────────────┘
│       │
│       │   下载中 → 进度条替代按钮
│       │   下载完成 → ✓ 对勾 + "使用中"
│       │
│       └── 底部：模型存储路径信息
│
├── 话题卡片 / 自定义话题 点击 →
│   │
│   │  检查模型是否可用 ─── 否 ──→ SnackBar「请先下载 AI 模型」
│   │                                    │
│   │                              点击跳转 ModelManagePage
│   │
│   └── 是 → ChatPage（正常进入）
│
└── 历史列表 → HistoryPage（不需要模型，直接进入）
```

---

## 二、页面设计

### 2.1 TopicSelectionPage — AppBar 入口

在现有 history 按钮左侧加一个模型管理入口：

```dart
AppBar(
  actions: [
    // ── NEW: 模型管理入口 ──
    TextButton.icon(
      onPressed: () => Navigator.push(context, 
        MaterialPageRoute(builder: (_) => const ModelManagePage())),
      icon: const Icon(Icons.memory, size: 18),
      label: const Text('模型'),
      style: TextButton.styleFrom(foregroundColor: AppTheme.textSecondary),
    ),
    // ── 现有: 历史记录 ──
    IconButton(
      icon: const Icon(Icons.history, color: AppTheme.textSecondary),
      tooltip: '历史对话',
      onPressed: () => Navigator.push(context, 
        MaterialPageRoute(builder: (_) => const HistoryPage())),
    ),
  ],
)
```

> 视觉上就是一个带文字的小按钮，和右侧 history 图标并列，不会太突兀。

### 2.2 ModelManagePage — 模型管理页

页面结构：

```
┌─────────────────────────────────────┐
│ ← 模型管理                          │  (AppBar)
├─────────────────────────────────────┤
│                                     │
│  ┌─────────────────────────────┐   │
│  │ 🧠 Qwen2.5-1.5B             │   │
│  │ 中文苏格拉底对话，端侧推理    │   │
│  │ Q4_K_M 量化 · ~1.06 GB      │   │
│  │                       [下载] │   │  ← 按钮区域
│  └─────────────────────────────┘   │
│                                     │
│  下载中的卡片变化：                   │
│  ┌─────────────────────────────┐   │
│  │ 🧠 Qwen2.5-1.5B             │   │
│  │ ████████░░░░ 42%            │   │  ← 进度条
│  │ 456 MB / 1.06 GB · 3.2 MB/s │   │  ← 详情行
│  │ 剩余 3 分钟         [取消]   │   │  ← 操作行
│  └─────────────────────────────┘   │
│                                     │
│  下载完成的变化：                     │
│  ┌─────────────────────────────┐   │
│  │ 🧠 Qwen2.5-1.5B        ✓ 已 │   │  ← 对勾
│  │ 中文苏格拉底对话，端侧推理    │   │
│  │ Q4_K_M 量化 · ~1.06 GB      │   │
│  │ 模型已就绪，可以开始对话了    │   │  ← 状态文字
│  └─────────────────────────────┘   │
│                                     │
│  ── 底部信息 ──                      │
│  存储位置: /Documents/models/...    │
│                                     │
└─────────────────────────────────────┘
```

**按钮状态机：**

```
[未下载]
  "下载" (outlined button)
     ↓ 点击
[下载中]
  进度条替换按钮区域
  "取消" (text button)
     ↓ 完成 / 取消
[已下载]
  ✓ 对勾图标 + "已就绪" 
  （未来可加 "切换" / "删除" 操作）
```

---

## 三、模型数据模型

```dart
/// 可下载的模型定义
class AvailableModel {
  final String id;           // "qwen2.5-1.5b-q4km"
  final String name;         // "Qwen2.5-1.5B"
  final String description;  // "中文苏格拉底对话..."
  final String quant;        // "Q4_K_M"
  final int sizeBytes;       // ~1.06GB
  final String downloadUrl;  // HuggingFace 直链
  final String mirrorUrl;    // hf-mirror 国内镜像
  final String fileName;     // "qwen2.5-1.5b-instruct-q4_k_m.gguf"
}
```

MVP 只有一个模型实例。结构预留了多模型扩展空间。

---

## 四、功能门控（Feature Gating）

需要模型的操作前，统一调用检查：

```dart
/// 检查是否有可用模型
bool isModelAvailable() {
  final path = AppConstants.defaultModelPath;
  return File(path).existsSync();
}
```

**使用位置：**

| 页面/操作 | 触发时机 | 无模型时的行为 |
|-----------|----------|----------------|
| TopicSelectionPage → 点击话题卡片 | `onTap` 回调 | `SnackBar("请先下载 AI 模型", action: "去下载")` → 跳转 ModelManagePage |
| TopicSelectionPage → 自定义话题提交 | `onSubmitted` 回调 | 同上 |
| ChatPage → 页面进入后自动 | `initState` 中 loadModel() | 已有 `hasModelError` 机制，显示加载失败页面 |
| InsightsPage → 重新生成洞察 | 按钮点击 | SnackBar + 不执行 |
| MindMapPage → 重新生成图谱 | 按钮点击 | SnackBar + 不执行 |
| HistoryPage | 任何操作 | **不需要模型**，跳过检查 |

> ChatPage 的 `loadModel()` 已经有错误处理（`hasModelError` + 重试页面），如果模型文件不存在，llama.cpp 会报错 → 已有的错误页可以兜底。所以 ChatPage 可以不额外加检查，让现有的错误处理链路自然覆盖。

---

## 五、组件清单

| 组件 | 文件 | 职责 |
|------|------|------|
| `AvailableModel` | `core/models/available_model.dart` | 模型定义数据类 |
| `ModelDownloadService` | `core/engine/model_download_service.dart` | dio HTTP Range 断点续传 |
| `ModelDownloadProvider` | `features/chat/providers/model_download_provider.dart` | 下载状态 + 进度 + 速度 + ETA |
| `ModelManagePage` | `features/chat/model_manage_page.dart` | 模型列表 + 下载交互 |
| `isModelAvailable()` | `core/constants.dart` 或独立工具 | 门控检查函数 |
| Mock 模型列表 | `core/constants.dart` | `AppConstants.availableModels` |

**依赖：** `dio` + `path_provider`（需 `flutter pub add`）

---

## 六、与原方案 V1 的对比

| 维度 | V1（强制启动门） | V2（按钮入口 + 门控） |
|------|:--:|:--:|
| 用户体验 | 打开 App 就被堵住 | 先看到功能，再决定下载 |
| 开发体验 | 改变启动流程 | 只加一个按钮和页面 |
| 多模型扩展 | 需要改造启动逻辑 | 页面天然支持列表 |
| 下载失败 | 卡在启动页无法退出 | 可以返回首页，稍后再试 |
| 已下载用户 | 每次启动都要检查一遍 | 直接进入，按钮变勾 |

---

## 讨论点

1. **按钮样式**：AppBar 里放 `IconButton(Icons.memory)` 不带文字 vs `TextButton.icon('模型')` ？前者更干净，后者信息更明确。

2. **模型卡片上的操作**：下载完成后，除了对勾，要不要加「使用此模型」按钮？（MVP 就一个模型，自动使用，可以先不加）

3. **历史列表里的会话**：如果用户删了模型，历史对话的洞察总结/图谱还在 DB 里有缓存，但点「重新生成」时会失败 → SnackBar 提示即可。

4. **ChatPage 的门控**：是 TopicSelectionPage 拦（点击话题时就检查），还是 ChatPage 自己拦（进去后发现没模型再提示）？推荐前者——在入口就拦，避免用户进去后发现白屏。
