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
| ☁️ 云端对话（可选） | BYOK 自带模型 API（baseUrl/key/模型名），端侧直连任意 OpenAI 兼容端点，不经过本应用服务端 |
| 📊 全局面板 | Dashboard 三区：目标与策略 / 执行路线 / 洞察 |
| 🔍 自动提取 | 每次对话结束，LLM 提取目标/策略/洞察，用户确认后生效 |
| 🔔 智能推送 | 服务端定时扫描 deadline，规则模式 + DeepSeek LLM 模式可选 |
| 🔗 跨对话关联 | 对话时注入已有目标供助手检测重叠并建议合并；提取回写按目标 id / 同名映射到已有目标，不产生重复项 |
| 🧠 端侧推理 | llama.cpp + Qwen3.5-2B，全程离线 |

## 技术栈

| 层 | 技术 |
|------|------|
| UI | Flutter 3.x + Provider |
| 端侧推理 | llama.cpp + Qwen3.5-2B (Q4_K_M) |
| 加速 | Metal（GPU 层数可调，默认纯 CPU） |
| 本地存储 | sqflite (SQLite) |
| 服务端 | Node.js + Express + node-cron |
| 推送通道 | 服务端触发 + WebSocket 站内横幅（不走系统推送） |
| 服务端 LLM | DeepSeek Chat API（用户可选开启） |

## 快速开始

```bash
git clone https://github.com/SuperJieLab/zhixing-ai.git
cd zhixing-ai

# Flutter App
flutter pub get
flutter run

# 服务端（推送功能，可选）
cd server && cp .env.example .env && npm install && npm start
```

启动后在首页右上角「模型管理」（内存图标）下载模型（Qwen3.5-2B Q4_K_M，约 1.27GB）即可开始使用。推送功能依赖服务端运行，未启动时 App 照常工作，只是没有推送提醒。

## 项目结构

```
lib/
├── core/
│   ├── constants.dart      # 全局常量（端侧模型参数 local* / 云端输入预算 cloud* / 服务端地址）
│   ├── logger.dart         # 统一日志
│   ├── model_gateway.dart  # 业务唯一门面（对话面编排 + 单次补全透传/截断）
│   ├── context/            # 上下文管理域（装配骨架 / 双端策略 / 摘要提示词，零 llm 依赖）
│   ├── llm/                # 大模型服务域：generation（流式生成）/ single_shot（单次）/ engine（端侧引擎池）
│   ├── data/               # 数据域（models/ + repository/ + ConversationService）
│   ├── platform/           # 平台基建（推送/WS/同步）
│   └── ui/                 # 跨 feature UI 基建（主题/路由观察/横幅）
├── features/
│   ├── chat/               # 助手对话
│   ├── dashboard/          # 全局面板（三区视图）
│   ├── strategy_brief/     # 对话结束提取确认页
│   ├── history/            # 对话历史列表
│   ├── settings/           # 偏好设置（云端 BYOK / GPU 加速）
│   └── model_manager/      # 模型下载管理 UI
├── app.dart                # MaterialApp 根（主题 / 路由观察 / 全局横幅）
└── main.dart               # 组合根：依赖装配 + 启动

server/                     # 服务端推送
├── src/
│   ├── index.js            # Express 入口 + cron 调度 + WS /ws
│   ├── routes/sync.js      # POST /api/sync 接收端侧数据
│   └── services/
│       ├── push.js         # 推送决策分发
│       ├── rules-engine.js # 规则模式
│       ├── llm-engine.js   # DeepSeek LLM 模式
│       └── wsHub.js        # token → socket 登记与下发
├── tests/                  # server 侧测试（push / wsHub）
├── .env.example
└── package.json

test/                       # 测试（目录结构与 lib/ 同构）
├── core/
│   ├── model_gateway_test.dart  # 门面编排（装配 → 生成 → 溢出自愈）
│   ├── context/            # 装配 / 双端策略 / 摘要提示词
│   ├── llm/                # generation（端侧重放、云端 SSE）/ single_shot（输入守门、端侧单次推理）/ llm_service
│   ├── data/repository/    # 设置仓库
│   └── platform/           # PushSocketService
├── features/
│   ├── chat/               # page / providers / widgets / utils / prompt
│   ├── dashboard/          # Dashboard 渲染测试
│   ├── history/            # History 页面测试
│   ├── strategy_brief/     # 提取链路（provider）+ 目标匹配
│   └── model_manager/      # 模型下载测试
└── support/fake_llm.dart   # FakeGateway + FakeLlm（业务侧测试统一假件）
tool/                       # 独立脚本（dart run 运行）
├── llama_integration_test.dart   # 端侧推理集成测试
└── cloud_smoke.dart              # 云端 BYOK 连通性冒烟
docs/                       # 设计文档
├── PROJECT.md              # 架构主文档（分层 / 数据模型 / 决策 / 版本）
├── plans/                  # 按日期归档的设计（*-design.md）与计划（*-plan.md）
└── notes/2026-09-11/       # 端侧 KV 复用可行性评估（技术证据）
```

> 完整架构、数据模型、设计决策见 [`docs/PROJECT.md`](docs/PROJECT.md)

## License

MIT
