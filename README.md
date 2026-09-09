# 知行AI — 人生管理规划助手

> 端侧 AI 帮你理清目标、制定策略，服务端推送确保执行到位。
> 对话全程端侧推理，隐私零上传。

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.x-0175C2?logo=dart)](https://dart.dev)
[![Node.js](https://img.shields.io/badge/Node.js-22.x-339933?logo=nodedotjs)](https://nodejs.org)

## 一句话

通过深度对话帮你设定目标、拆解策略、追踪执行的 AI 助手——端侧保障隐私，云端增强推送。

## 核心闭环

```
对话 → 提取目标/策略 → Dashboard 追踪 → 推送提醒
  ↑                                        │
  └────────── 根据反馈调整 ────────────────┘
```

## 核心功能

| 功能 | 说明 |
|------|------|
| 🎯 助手对话 | AI 主动分析、拆解、建议，注入已有目标检测重叠，建议合并而非新增 |
| 📊 全局面板 | Dashboard 三区：目标与策略 / 执行路线 / 跨对话洞察 |
| 🔍 自动提取 | 每次对话结束，LLM 提取目标/策略/洞察，用户确认后生效 |
| 🔔 智能推送 | 服务端定时扫描 deadline，规则模式 + DeepSeek LLM 模式可选 |
| 🔗 跨对话关联 | 同名目标自动合并，发现跨对话模式与矛盾 |
| 🧠 端侧推理 | llama.cpp + Qwen3.5-2B，全程离线 |

## 技术栈

| 层 | 技术 |
|------|------|
| UI | Flutter 3.x + Provider |
| 端侧推理 | llama.cpp + Qwen3.5-2B (Q4_K_M) |
| 加速 | CoreML (iOS) / Metal (macOS) / NNAPI (Android) |
| 本地存储 | sqflite (SQLite) |
| 服务端 | Node.js + Express + node-cron |
| 推送通道 | Firebase Cloud Messaging (APNs + FCM) |
| 服务端 LLM | DeepSeek Chat API（用户可选开启） |

## 快速开始

```bash
git clone https://github.com/SuperJieLab/socratic-ai.git
cd socratic-ai

# Flutter App
flutter pub get
flutter run

# 服务端（推送功能，可选）
cd server && cp .env.example .env && npm install && npm start
```

启动后在 App 设置页下载模型（~1.06GB）即可开始使用。推送功能依赖服务端运行，未启动时 App 照常工作，只是没有推送提醒。

## 项目结构

```
lib/
├── core/
│   ├── engine/             # LLM 引擎 + 对话管理
│   ├── models/             # 共享数据模型
│   ├── repository/         # 数据访问层 (sqflite)
│   └── services/           # PushService + SyncService
├── features/
│   ├── chat/               # 助手对话
│   ├── dashboard/          # 全局面板（三区视图）
│   ├── strategy_brief/     # 对话结束提取确认页
│   ├── history/            # 对话历史列表
│   └── model_manager/      # 模型下载管理 UI
└── main.dart

server/                     # 服务端推送
├── src/
│   ├── index.js            # Express 入口 + cron 调度
│   ├── routes/sync.js      # POST /api/sync 接收端侧数据
│   └── services/
│       ├── push.js         # 推送决策分发
│       ├── rules-engine.js # 规则模式
│       └── llm-engine.js   # DeepSeek LLM 模式
├── .env.example
└── package.json

test/                       # 测试（目录结构与 lib/ 一一对应）
├── smoke_test.dart         # 全流程冒烟测试（app 级，留根目录）
├── core/
│   └── services/           # PushSocketService 等核心服务测试
├── features/
│   ├── chat/
│   │   ├── engine/         # ChatClient/策略/SSE/Markdown 块切分测试
│   │   ├── providers/      # ChatProvider 测试
│   │   ├── widgets/        # 气泡/输入框渲染测试
│   │   └── *_page_test.dart
│   ├── dashboard/          # Dashboard 渲染测试
│   ├── history/            # History 页面测试
│   └── model_manager/      # 模型下载测试
tool/
└── llama_integration_test.dart   # 端侧推理集成测试（dart run 独立运行）
```

> 完整架构、数据模型、设计决策见 [`docs/PROJECT.md`](docs/PROJECT.md)

## License

MIT
