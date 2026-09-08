# 流式对话设计：SSE 云端通道 + 流式 Markdown 渲染

> 日期：2026-09-07
> 状态：设计定稿（实现计划见 `2026-09-07-streaming-chat-plan.md`）
> 知识来源：`~/Library/CloudStorage/OneDrive-个人/Work/InterviewFiles/learning-notes/AI/02-AI流式对话技术栈精要-SSE与Markdown渲染.md`

## 一、背景与动机

学习笔记《AI 流式对话技术栈精要》对应 JD 要求「AI 对话、SSE 流式输出、Markdown 渲染」，且文末动手清单明确指向本项目。落地前对项目现状做了事实核查，与笔记的假设有三处出入：

| 笔记假设 | 项目现状 |
|---|---|
| 后端是 Go | 服务端是 Node.js/Express |
| 流式链路不存在 | 端侧**已流式**：`StrategistPrompter.generateResponse()` 返回 `Stream<String>`（llama.cpp 逐 token） |
| 需建整套链路 | 真正缺口：① `ChatBubble` 是纯 `Text`，零 Markdown 渲染；② `llm-engine.js` 调 DeepSeek 非流式（无 `stream:true`） |

因此本设计不是"从零建流式"，而是**补两个缺口**：流式 Markdown 渲染器（轨道 A）+ SSE 云端通道（轨道 B）。

## 二、核心决策

### 决策 1：双路径统一收敛到 `Stream<String>`，渲染器共用

```
端侧：llama.cpp → StrategistPrompter.generateResponse() → Stream<String>   （已有）
云端：DeepSeek → Node /api/chat (SSE) → SseParser + CloudChatClient → Stream<String>   （新增）
                          ↓ ChatProvider 按模式选择数据源
                          ↓
          StreamingMarkdownRenderer（块级切分 + 未闭合块降级 + 已闭合块缓存）
                          ↓
                      ChatBubble
```

- 渲染器只关心"全量文本随时间增长"，不关心 token 从哪来。两条路径天然同构。
- 端侧路径装上渲染器**立刻受益**（不依赖网络）；SSE 是第二个数据源，可独立开关。

### 决策 2：云端模式默认关闭，端侧为默认

"隐私零上传"是产品核心卖点。云端模式做成 `SettingsRepository` 里的显式开关（默认 `false`），开启即用户明确同意把对话内容发往 DeepSeek。与既有设置项三步约定一致（Repository key → Provider 透传 → SettingsPage 开关）。

### 决策 3：自研块级流式渲染 + `markdown` 包做 AST，不用 `flutter_markdown`

- `flutter_markdown` 已停维护（Flutter 官方已废弃），不可引入。
- 块级切分/未闭合块降级/增量渲染的策略本身**必须自研**（这正是技术价值所在），叶子渲染用 Dart 官方 `markdown` 包解析 AST 后映射为 Widget。
- 不渲染原始 HTML（`markdown` 包默认不执行），LLM 输出不可信，天然规避 XSS；链接协议白名单仅 http/https。
- 代码高亮后置：未闭合代码块纯文本显示，闭合后再整块渲染（高亮库引入放 v2）。

## 三、模块设计

### 3.1 轨道 A：StreamingMarkdownRenderer

**归属**（符合分层规范：engine 无 UI，widget 只依赖 engine 产物）：

- `features/chat/engine/markdown_blocks.dart` — 纯函数块级切分
- `features/chat/widgets/markdown_message_view.dart` — 渲染 Widget

**块级切分**（纯函数，可单测）：

```dart
/// 把随时间增长的全量文本切成 Markdown 块列表。
/// 返回 (closedBlocks, tailBlock)：
///   closedBlocks — 已闭合块（空行分隔，fence 配对完整），内容不会再变
///   tailBlock    — 最后一个未闭合块（可能是半个段落/表格/代码块）
(List<String> closed, String tail) splitBlocks(String fullText);
```

规则：
- 以空行（`\n\n`）切块；未闭合的 ```` ``` ```` fence 之后的全部内容并入 tail
- tail 永远是列表最后一段，闭合瞬间升级为 closed（每个块只升级一次，不横跳）

**渲染策略**：
- `MarkdownMessageView` 为 StatefulWidget，内部缓存 `Map<String, Widget>`（key = 块文本）。closed 块文本不变 → 缓存命中，Flutter 直接复用；每次 delta 只重建 tail 块 → O(n) 而非 O(n²)。
- closed 块：`markdown` 包解析 AST → 段落/标题/代码块/列表/表格映射为 Material Widget
- tail 块：降级纯文本（同气泡字体），闭合后下一帧自动升级
- 这是流式不闪烁的关键：历史块永远不重渲染

**接入点**：`chat_bubble.dart` 的 `Text(message.content)` 替换为 AI 消息时用 `MarkdownMessageView`（用户消息保持纯文本）。

### 3.2 轨道 B：云端 SSE 通道

**服务端**（Node，遵循 `/api/sync` 同款路由模式）：

- `server/src/services/sse-parse.js` — 纯函数：从上游 DeepSeek SSE 流中提取 `choices[0].delta.content`（node:test 单测）
- `llm-engine.js` 加 `streamChatCompletion(messages, { onDelta, signal })`：`fetch` 开 `stream:true` + `AbortController`，逐帧读上游 body，解析出 delta 后回调
- `server/src/routes/chat.js` — `POST /api/chat`：
  - 请求体 `{ messages: [{role, content}] }`（客户端截尾窗口，服务端不落库）
  - 响应头 `Content-Type: text/event-stream` + `Cache-Control: no-cache`
  - 每帧 `res.write('data: {"delta":"..."}\n\n')`，Express 无输出缓冲；若日后挂 Nginx 需加 `X-Accel-Buffering: no`
  - `req.on('close')` → `AbortController.abort()` → 上游 DeepSeek 停止推理（**取消传播**，省 token 费用）
  - 结束发 `data: [DONE]\n\n`
  - 无 `DEEPSEEK_API_KEY` → 501 明确报错（客户端回退端侧模式）

**客户端**（`features/chat/engine/`，复用已有 `dio` 依赖，不引新传输库）：

- `sse_parser.dart` — 纯函数帧缓冲状态机：

```dart
/// 喂入一个网络 chunk，返回其中完整帧的 data 内容（可能 0~N 条）。
/// 半包（帧被拆在两个 chunk 间）由内部 buffer 兜住。
List<String> feedSseChunk(SseBuffer buffer, String chunk);
```

  与 IM 同构：`\n\n` 帧边界 ≈ 消息 index 连续性；半包 buffer ≈ 空洞补偿。
- `cloud_chat_client.dart` — dio `ResponseType.stream` → `utf8.decoder`（处理多字节汉字跨 chunk）→ `feedSseChunk` → `Stream<String>` yield delta，签名与 `StrategistPrompter.generateResponse()` 对齐；`stop()` 触发 dio CancelToken。

### 3.3 ChatProvider 集成与停止生成

- `ChatMode { local, cloud }`，`sendMessage` 按模式选数据源，下游 `await for (token in ...)` 结构不变
- **停止生成**：`await for` 改为持有 `StreamSubscription`，`stopGeneration()` 取消订阅、保留已生成文本；云端模式同时调 `CloudChatClient.stop()` → 服务端感知断连 → abort 上游（取消传播全链路）
- **帧间空闲超时**：云端模式下 N 秒无新 delta 判定流挂掉 → 丢弃半截回答、提示重试（LLM 场景不做 Last-Event-ID 续传——token 流不可续，这是与典型 SSE 场景的关键差异）
- 设置项：`SettingsRepository` 加 `chatCloudMode`（默认 false）→ `SettingsProvider` 透传 → `SettingsPage` 加开关，附隐私说明文案

## 四、容错设计

| 场景 | 处理 |
|---|---|
| SSE 半包/粘包 | `SseBuffer` 内部缓冲，`\n\n` 切帧，残缺尾巴留待下一 chunk |
| 汉字 UTF-8 跨 chunk | dio 字节流先过 `utf8.decoder` 再喂帧解析 |
| 云端连接失败 | 错误上抛 → Provider 显示错误 + 自动回退端侧 Mock（与现有 `loadModel` 失败路径同构） |
| 无 API Key | 服务端 501；客户端读 Settings 开关前先探测，直接隐藏云端选项 |
| 用户停止生成 | 客户端 cancel + 服务端 `req.on('close')` abort 上游，取消传播全链路 |
| 流中途挂死 | 帧间空闲超时（10s），丢弃半截、提示重试，不续传 |

## 五、验证手段（查产物不查文本）

1. **块级切分**：纯函数单测——正常段落、未闭合 fence、表格半行、`**加粗` 半截
2. **SSE 解析**：node:test（服务端）+ Dart 单测（客户端）——半包、一 chunk 多帧、`[DONE]`
3. **服务端流式**：`curl -N POST /api/chat` 目视逐帧到达（非一次性吐出）
4. **取消传播**：curl 发起后 Ctrl-C，观察服务端日志 abort 上游 + DeepSeek 后台用量不再增长
5. **端到端**：模拟器开云端模式发消息 → 顶部横幅无、气泡内文字逐字出现且 Markdown 块闭合时不闪烁；`flutter analyze lib/` 0 error
6. **渲染正确性**：含代码块/表格/列表的回复，闭合块渲染样式正确、tail 块纯文本不横跳

## 六、v1 外范围（明确不做）

- 代码语法高亮（闭合块 v1 只做样式区分，高亮库 v2 引入）
- 数学公式 / Mermaid 图 / 图片渲染
- SSE 断线续传（Last-Event-ID）——LLM token 流不可续，只做"丢弃重试"
- 多轮上下文的云端会话持久化（服务端无状态透传，不落库）
- 云端模式下的 Prompter 人设注入（v1 云端用独立 system prompt，不与端侧 seedHistory 混用）

## 七、简历产出

做完后可写：**「实现双通道流式对话链路：SSE 帧解析状态机处理半包/粘包、服务端取消传播至 LLM 推理侧、块级增量 Markdown 渲染解决流式闪烁（O(n²)→O(n)）、帧间空闲超时与断线重试语义设计」**
