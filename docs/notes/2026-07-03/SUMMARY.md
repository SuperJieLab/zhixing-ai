# 2026-07-03 工作总结：Day 2 — 端侧推理接入（llama.cpp + Qwen3.5-2B）

## 完成事项

### 技术选型

评估了 3 个 Flutter llama.cpp 封装包，选择 `llama_cpp_dart` v0.9.0-dev.9（MIT、内置 Isolate、ChatML 支持、预编译二进制）。

### 三端预编译二进制集成

- `llama.xcframework`（iOS + macOS，17.7MB）→ `ios/Runner/`
- `llama-cpp-dart.aar`（Android arm64-v8a，2.3MB）→ `android/app/libs/`
- `macos-libllama.zip`（macOS dylibs）→ `macos/Runner/libs/`

### 核心代码

| 文件 | 作用 |
|------|------|
| `lib/core/llama_service.dart` | 推理服务单例：模型加载、流式 token、追问维度轮换、去重检测 |
| `lib/core/constants.dart` | 模型路径、上下文配置常量 |
| `lib/features/chat/providers/chat_provider.dart` | 异步 sendMessage + 流式 token 拼接 + Mock 回退 |

### 模型

- 初始：Qwen2.5-1.5B-Instruct Q4_K_M（~1.06GB）
- 最终升级：Qwen3.5-2B-Instruct Q4_K_M（~1.2GB），指令遵循能力更强

### 端到端验证（macOS M1 Pro）

- 引擎加载：13.4s（含 Metal shader 编译）
- 首轮推理：46.5 tok/s，次轮推理：71.3 tok/s
- Qwen3.5-2B 追问质量明显提升，think 标签自动剥离

## Bug 修复

| 问题 | 修复 |
|------|------|
| 多行字符串编译错误 | 添加分号 |
| Sandbox 文件读取被拒 | 从 `Platform.resolvedExecutable` 解析路径 |
| 模型加载成功但用 Mock | StatefulWidget + initState |
| `seedContext` 永不触发 | 改用 `_round == 1` 判断 |
| 消息不自动滚动 | addPostFrameCallback + animateTo |
| Qwen3.5 输出 think 标签 | `_stripThinkingTags()` 剥离 |
| Qwen3.5 模型加载失败 | Sandbox 白名单加新模型路径 |

## 测试结果

- `flutter analyze lib/`：0 error，0 warning
- `flutter test`：26/27 通过

## Git 提交

```
8a5a0b2 feat: Day 2 端侧推理接入 + LLM prompt 调优总结
a9e78e2 feat: 切换模型为 Qwen3.5-2B-Instruct Q4_K_M
b8c8b47 fix: 将新模型路径加入 Sandbox temporary-exception 白名单
b91477f fix: 剥离 Qwen3.5 的 <think> 推理内容
9cf097c fix: 完善 think 标签剥离逻辑 + 系统提示词禁用思考模式
```

## 待完成

- [ ] iOS/Android 编译验证
- ✅ 模型升级：Qwen2.5-1.5B → Qwen3.5-2B
- [ ] 对话总结（长对话上下文压缩）
- [ ] 动态维度选择
- [ ] 用户反馈收集

## 深度笔记

详见 `prompt-tuning-log.md`（LLM Prompt v1-v6 迭代全记录）
