# Socratic AI

苏格拉底式 AI 对话 — 一个通过追问帮你理清思路的 AI 对话 App。

## 项目概述

反过来的聊天机器人：AI 追问用户，而不是用户问 AI。通过苏格拉底式追问，帮助用户理清思路、发现认知盲区。

## 技术栈

- **前端**: Flutter 3.x + Provider
- **端侧推理**: llama.cpp (C++) + Dart FFI → Qwen 2.5 1.5B
- **后端**: Go + Gin + GORM + SQLite

## 快速开始

```bash
flutter pub get
flutter run
```

## 项目状态

MVP 开发中，详见 `docs/demo-plan-socratic-ai.md`
