# Socratic AI

> 反过来的聊天机器人：AI 追问你，而不是你问 AI。
> 端侧推理，隐私零上传。

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.x-0175C2?logo=dart)](https://dart.dev)

## 一句话

通过苏格拉底式追问帮你理清思路的 AI 对话 App —— AI 是提问者，你是回答者。

## 为什么做这个

99% 的 AI 产品是「你问它答」。我们做反向的 —— AI 追问你的底层假设、帮你发现思维盲区。

| 传统 AI Chatbot | Socratic AI |
|:--|:--|
| 给你答案，越用越依赖 | 帮你提问，越用越有独立思考能力 |
| 数据上云 | 对话全程在端侧推理 |
| 「告诉我怎么做」 | 「帮我想清楚我要什么」 |

## 核心功能

| 功能 | 说明 |
|------|------|
| 🎯 话题选择 | 5 个预设话题（职业/决策/自我探索/工作/人际）+ 自定义输入 |
| 💬 多轮追问 | 梯度追问策略（探索→深入→挑战→总结），自动适应短/长回答 |
| 🔍 洞察总结 | 端侧 LLM 分析全文，生成洞察卡片 + 价值观标签 + 认知矛盾高亮 |
| 🧠 思维图谱 | 端侧 LLM 生成图谱结构 → 辐射分布布局 → 可交互可视化（缩放/拖拽/点击） |
| 📂 历史列表 | 本地 sqflite 持久化，支持收藏和左滑删除 |
| 📥 模型管理 | HuggingFace 直链下载 + HTTP Range 断点续传 + 进度条 |

## 页面一览

| 话题选择 | 对话中 | 洞察总结 |
|:---:|:---:|:---:|
| *(截图占位)* | *(截图占位)* | *(截图占位)* |

| 思维图谱 | 历史列表 | 模型管理 |
|:---:|:---:|:---:|
| *(截图占位)* | *(截图占位)* | *(截图占位)* |

## 技术亮点

### 端侧推理，零隐私上传

- 对话全程在设备端完成，使用 llama.cpp + **Qwen 2.5 1.5B** (Q4_K_M, ~1.06GB)
- iOS 自动启用 CoreML 加速，Android 自动启用 NNAPI
- 对话原始内容不离开设备，只有脱敏后的图谱结构可同步

### Dart FFI 统一双端

- 一份 Dart 代码桥接 C++ 推理引擎，无需 Swift/Kotlin Native 代码
- 梯度追问策略（探索→深入→挑战→总结）+ 去重检测全部在 Dart 层完成
- Prompt 构建由 chat template 管理，Dart 层只注入追问方向标记

### 自研图谱布局

- 端侧 LLM 直接输出图谱 JSON 结构（节点 + 连线 + 权重）
- Dart 端自研辐射分布布局算法（无需 dagre/Graphviz 等外部库）
- Flutter CustomPainter 渲染 + 手势交互（双指缩放/拖拽/点击详情）

## 技术栈

| 层 | 技术 | 用途 |
|------|------|------|
| UI 框架 | Flutter 3.x | 跨平台 iOS + Android |
| 状态管理 | Provider | 对话 + 推理 + 下载状态 |
| 推理引擎 | llama.cpp (C++) | 编译进 App 的端侧推理 |
| Dart FFI | llama_cpp_dart | Dart ↔ C++ 桥接 |
| 模型 | Qwen 2.5 1.5B (Q4_K_M) | 中文苏格拉底对话 |
| 加速 | CoreML (iOS) / NNAPI (Android) | 自动启用硬件加速 |
| 持久化 | sqflite | SQLite 本地存储 |
| 网络 | dio | HTTP Range 断点续传 + API 调用 |
| 图谱布局 | 自研辐射分布 | 纯 Dart 原生算法 |
| 图谱渲染 | CustomPainter | Flutter Canvas 渲染 |

## 架构

```
┌─────────────────────────────────────────────┐
│              Flutter UI (Dart)              │
│   话题选择 │ 对话界面 │ 洞察总结 │ 思维图谱   │
│               │ Provider                     │
│    ┌──────────┴──────────┐                   │
│    │  Dart FFI 桥接       │                  │
│    │  llama_cpp_dart     │                  │
│    └──────────┬──────────┘                   │
│    ┌──────────┴──────────┐                   │
│    │  llama.cpp (C++)    │                  │
│    │  Qwen 2.5 1.5B      │                  │
│    │  CoreML / NNAPI     │                  │
│    └─────────────────────┘                   │
├─────────────────────────────────────────────┤
│  sqflite — SQLite 本地持久化                 │
│  conversations / messages / insights / graphs│
└─────────────────────────────────────────────┘
```

## 快速开始

### 前置条件

- Flutter 3.x
- Xcode (iOS/macOS) 或 Android SDK
- ~2GB 空闲存储（模型文件 ~1.06GB）

### 运行

```bash
git clone https://github.com/SuperJieLab/socratic-ai.git
cd socratic-ai
flutter pub get

# 启动应用后，通过 AppBar 的 🧠 图标进入模型管理页下载模型
flutter run
```

### 测试与分析

```bash
flutter test
flutter analyze
```

## 项目结构

```
lib/
├── core/                   # 基础设施
│   ├── engine/             # LlamaService, DialogueEngine, 下载服务
│   ├── models/             # 共享数据模型
│   ├── repository/         # ConversationRepository (sqflite)
│   ├── logger.dart         # 条件编译日志
│   ├── theme.dart          # 全局主题
│   └── constants.dart      # 常量 + 模型门控
├── features/               # Feature-first 组织
│   ├── chat/               # 对话引擎 + 追问策略 + UI
│   ├── insights/           # 洞察总结 + 价值观分析
│   ├── mindmap/            # 思维图谱生成 + 布局 + 渲染
│   ├── history/            # 历史列表 + 收藏
│   ├── topics/             # 话题选择
│   └── model_manager/      # 模型下载管理
└── main.dart               # 入口
```

## 项目状态

**MVP 核心功能完成。** 端侧推理 + 追问策略 + 洞察总结 + 思维图谱 + 本地持久化 + 模型下载全部就绪。

### 后续计划

- v1.1：话题推荐 + 语音输入
- v1.2：Watch 端触发 + 心率感知 + Web 端回顾台
- 高阶版：Go 后端 + 多端同步 + 用户系统

## License

MIT
