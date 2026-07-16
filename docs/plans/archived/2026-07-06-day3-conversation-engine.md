# Day 3 — 对话引擎完善

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 实现 PRD 定义的梯度追问策略、短回答检测、上下文管理、推理参数调优，确保 5+ 轮对话稳定。

**Architecture:** 所有改动集中在 `SocraticPrompter`（策略层）和 `LlamaService`（引擎层）。ChatProvider 和 DialogueEngine 接口不变。梯度策略替代当前固定维度轮换，追问方向随对话深度变化。

**Tech Stack:** Dart, llama_cpp_dart, Flutter

**Current vs Target Gap:**

| PRD Requirement | Current | Target |
|:--|:--|:--|
| 追问策略 | 固定 5 维度轮换 | 梯度：探索→深入→挑战→引导总结 |
| 短回答检测 | 无 | < 20 字注入具体化追问方向 |
| Context 管理 | 仅 nCtx=2048 | 添加 token 估算 + 截断保护 |
| 推理参数 | temp=0.85, topP=0.92, max=256 | temp=0.5, topP=0.85, max=128, repeat_penalty=1.15 |
| Prompt 规则 | 5 条简化规则 | 对齐 PRD 6 条规则 |

---

## 文件结构（改动范围）

```
lib/core/engine/
├── socratic_prompter.dart   # 重写：梯度策略 + 短回答检测 + 参数调优
├── llama_service.dart       # 微调：添加 token 估算 + repeat_penalty
├── dialogue_engine.dart     # 不变
lib/core/models/
└── chat_models.dart         # 不变
lib/features/chat/
└── providers/
    └── chat_provider.dart   # 不变
test/features/chat/providers/
└── chat_provider_test.dart  # 更新：适配新策略的测试
```

---

### Task 1: 梯度追问策略 + 短回答检测

**Files:**
- Modify: `lib/core/engine/socratic_prompter.dart`

**核心逻辑：**

将当前固定维度轮换改为按 `_roundIndex` 决定追问方向，同时检测用户回答长度。

```
追问阶段映射：
  round 1    → exploration   "帮用户展开这个话题"
  round 2-3  → deepening     "追问具体细节或例子"  
  round 4-6  → challenge     "挑战底层假设或换个角度"
  round 7+   → summary       "引导回顾对话收获"

短回答（< 20 字）→ 自动升级到 deepening（无论当前阶段）
```

**Step 1: 定义追问阶段枚举**

在 `socratic_prompter.dart` 顶部新增：

```dart
/// 追问阶段（随对话深度变化）
enum _ProbeStage { exploration, deepening, challenge, summary }

/// 每个阶段的追问方向提示（注入到用户消息中）
const _stageHints = <_ProbeStage, String>{
  _ProbeStage.exploration:
      '追问方向：【探索】帮用户展开这个话题，问一个开放性的问题',
  _ProbeStage.deepening:
      '追问方向：【深入】追问具体细节或例子，比如"具体是指什么"或"能举一个例子吗"',
  _ProbeStage.challenge:
      '追问方向：【挑战】挑战用户的底层假设，比如"如果换个角度呢"或"你为什么这么认为"',
  _ProbeStage.summary:
      '追问方向：【总结】引导用户回顾对话，比如"今天聊的这些，你最大的收获是什么"',
};
```

**Step 2: 替换维度轮换为阶段判断**

```dart
/// 短回答阈值（中文字符数）
static const int _shortAnswerThreshold = 20;

_ProbeStage _currentStage(int round, String userMessage) {
  // 短回答优先升级到深入追问
  if (userMessage.length < _shortAnswerThreshold) {
    return _ProbeStage.deepening;
  }
  
  if (round <= 1) return _ProbeStage.exploration;
  if (round <= 3) return _ProbeStage.deepening;
  if (round <= 6) return _ProbeStage.challenge;
  return _ProbeStage.summary;
}
```

**Step 3: 更新 generateResponse**

在 `generateResponse` 中：
1. 用 `_currentStage(round, userMessage)` 替代 `_getCurrentDimension()`
2. 把 stage hint 注入用户消息格式化
3. 重试时也用相同 stage（而非切换维度）

**Step 4: 更新系统提示词**

重新对齐 PRD 的 6 条规则：

```dart
const _socraticSystemPrompt = '''
你是一位苏格拉底式对话教练。你不会给建议或答案，你只通过提问帮用户自己找到答案。

**重要：直接输出追问问题，不要输出思考过程。**

## 对话规则
1. 每次只输出一个问题，不要附带任何解释
2. 问题必须基于用户刚才的回答深入挖掘
3. 如果用户回答比较浅，追问具体化：「你说的XX具体是指什么？」
4. 如果用户提出了一个判断，追问假设：「是什么让你这样认为？」
5. 如果发现用户前后矛盾，温和指出：「你之前说XX，现在说YY，这之间的变化是因为什么？」
6. 当对话达到足够深度，输出 [SUMMARY] 标记并给出洞察总结

用户消息中带有"追问方向"标记，你只需要基于该方向追问一个问题。
问题控制在 150 字以内，用中文，不要给建议，不要一次问多个问题。
''';
```

---

### Task 2: Context 窗口管理

**Files:**
- Modify: `lib/core/engine/llama_service.dart`

**核心逻辑：**

在 `LlamaService` 添加简易 token 估算方法。llama.cpp 的 KV cache 会自动截断（nCtx=2048），Dart 层只是监控 + 日志警告。

**Step 1: 添加 token 估算器**

```dart
/// 估算文本的 token 数量（粗略：中文≈1.5x，英文≈0.25x）
int estimateTokens(String text) {
  int chineseCount = 0;
  int otherCount = 0;
  for (final char in text.runes) {
    final code = char;
    // CJK Unified Ideographs range
    if ((code >= 0x4E00 && code <= 0x9FFF) ||
        (code >= 0x3400 && code <= 0x4DBF)) {
      chineseCount++;
    } else {
      otherCount++;
    }
  }
  return (chineseCount * 1.5 + otherCount * 0.25).ceil();
}
```

**Step 2: 设置 repeat_penalty**

检查 `llama_cpp_dart` 的 `SamplerParams` 是否支持 `repeatPenalty`，如果有则设置 1.15。

```dart
// 在 generate() 方法中：
sampler: SamplerParams(
  temperature: temperature,
  topP: topP,
  repeatPenalty: repeatPenalty,  // 如果 API 支持
),
```

---

### Task 3: 推理参数调优

**Files:**
- Modify: `lib/core/engine/socratic_prompter.dart`

**Step 1: 更新 generateResponse 中的 generate 调用参数**

```dart
// 当前：
await for (final token in _llm.generate(
  temperature: 0.85,
  topP: 0.92,
  maxTokens: 256,
))

// 改为 PRD 规范：
await for (final token in _llm.generate(
  temperature: 0.5,
  topP: 0.85,
  maxTokens: 128,
  // repeatPenalty: 1.15,  // 如果 SamplerParams 支持
))
```

---

### Task 4: 更新单元测试

**Files:**
- Modify: `test/features/chat/providers/chat_provider_test.dart`

**Step 1: 适配新的阶段判断**

现有的 Mock 逻辑不变（Mock 不经过 SocraticPrompter），主要验证：
- ChatProvider 兼容新接口（DialogueEngine 接口未变）
- 如果有自定义 Mock 引擎的测试，确保它们仍然通过

---

### Task 5: 移除旧代码

**Files:**
- Delete 或清理 `socratic_prompter.dart` 中以下不再需要的部分：
  - `_dimensions` 常量
  - `_getCurrentDimension()` 方法
  - 维度相关的重试逻辑（阶段切换替代维度切换）

---

### Task 6: 手动验证

不用自动化测试。手动跑一次完整对话验证：

**验证清单：**
- [ ] 选择「职业发展」→ 欢迎消息正确
- [ ] Round 1：用户回答后 → AI 追问是探索性的（不偏离主题）
- [ ] Round 2-3：追问越来越深入（"具体指什么"、"举个例子"）
- [ ] Round 4-6：开始挑战假设（"换个角度呢"）
- [ ] Round 7+：引导总结
- [ ] 用户回答很短（如"嗯"、"是的"）→ AI 追问具体化
- [ ] 5+ 轮对话不跑偏
- [ ] 无重复问题
- [ ] 每轮延迟 < 5 秒

---

### Task 7: Commit

```bash
git add lib/core/engine/socratic_prompter.dart lib/core/engine/llama_service.dart test/
git commit -m "feat(day3): gradient probe strategy + short answer detection + context management

- Replace fixed dimension rotation with gradient probe stages
  (exploration → deepening → challenge → summary)
- Add short answer detection (< 20 chars triggers deepening)
- Align system prompt to PRD 6 rules
- Tune inference params: temp 0.5, topP 0.85, maxTokens 128
- Add token estimator for context monitoring
- Remove deprecated dimension rotation code"
```
