# 知行AI — 人生管理规划助手

> 像助手一样理解你，帮你拆解目标、制定策略、追踪执行。
> 端侧推理，隐私零上传。

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.x-0175C2?logo=dart)](https://dart.dev)

## 一句话

通过深度对话帮你理清目标、制定策略的 AI 助手 —— AI 是助手，你是用户。

## 为什么做这个

大多数 AI 产品是"你问它答"，聊完就忘。知行AI 做反向的：

| 传统 AI Chatbot | 知行AI |
|:--|:--|
| 给你答案，越用越依赖 | 帮你拆解，越用越有方向感 |
| 聊完即忘，每次从零开始 | 每次对话汇入全局视图，目标/策略持续追踪 |
| 数据上云 | 对话全程端侧推理，隐私零上传 |

## 核心功能

| 功能 | 说明 |
|------|------|
| 🎯 助手对话 | AI 主动分析、拆解、建议，帮用户理清思路 |
| 📊 全局面板 | 所有对话汇入统一视图：目标 + 策略 + 跨对话洞察 |
| 🔍 自动提取 | 每次对话结束，LLM 自动提取目标/策略/约束 |
| 🔗 跨对话关联 | 同名目标自动合并，发现跨对话共性模式或矛盾 |
| 🧠 端侧推理 | llama.cpp + Qwen3.5-2B，全程离线 |

> 完整项目定义、架构、数据模型见 [`docs/PROJECT.md`](docs/PROJECT.md)

## 技术栈

| 层 | 技术 |
|------|------|
| UI | Flutter 3.x + Provider |
| 推理 | llama.cpp + Qwen3.5-2B (Q4_K_M) |
| 加速 | CoreML (iOS) / Metal (macOS) / NNAPI (Android) |
| 存储 | sqflite (SQLite) |
| 下载 | dio (HTTP Range 断点续传) |

## 快速开始

```bash
git clone https://github.com/SuperJieLab/socratic-ai.git
cd socratic-ai
flutter pub get
flutter run
```

启动后通过 🧠 图标进入模型管理页下载模型（~1.06GB），即可开始使用。

## 项目结构

```
lib/
├── core/                   # 基础设施 (engine/models/repository/theme)
├── features/
│   ├── chat/               # 助手对话
│   ├── dashboard/          # 全局面板
│   ├── strategy_brief/     # 对话结束大局影响页
│   ├── history/            # 历史列表
│   ├── model_manager/      # 模型下载管理
│   └── _deprecated/        # v1 旧代码保留（洞察/图谱/话题选择）
└── main.dart
```

## 项目状态

**v2（助手模式）基础设施完成。** Dashboard + Chat + StrategyBrief + 目标提取链路已实现。

### 后续方向

- 端侧走通完整助手对话流程（StrategistPrompter 实际推理验证）
- 目标/策略的手动编辑能力
- 服务端推送提醒（依赖后端就绪）
- Watch 端触发器 + 传感器

## License

MIT
