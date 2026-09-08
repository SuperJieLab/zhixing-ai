# 流式对话实现计划：SSE 云端通道 + 流式 Markdown 渲染

> 日期：2026-09-07
> 设计依据：`2026-09-07-streaming-chat-design.md`（先读它，本文只讲怎么做）
> 执行方式：子代理逐 Task「实现 → 规格审查 → 代码质量审查」，同 in-app-push 流程
> 提交纪律：**每个 Task 完成后停在"待用户确认提交"，不自动 commit**；作者 superjie、无 Co-Authored-By、仅本地

## 环境事实（实现前必读）

- 客户端已有依赖：`dio ^5.7.0`（SSE 传输用它，**不引 http 包**）、`provider ^6.1.2`
- 需新增依赖：`markdown: ^7.0.0`（Dart 官方 AST 解析器；flutter_markdown 已停维护，禁用）
- 端侧已流式：`strategist_prompter.dart:63` `Stream<String> generateResponse()`
- 服务端路由模式：`index.js` 中 `app.use('/api/sync', syncRouter)` 照抄
- `llm-engine.js:72` 现为非流式 `fetch`，保留不动（push 决策用），流式走新函数
- 沙箱限制：`flutter test` 跑不了（环境问题非代码问题），Dart 单测用逻辑核查 + analyze；node:test 可正常跑
- `flutter analyze` 必须 0 error / 0 warning

## Task 1：块级切分纯函数（轨道 A 地基）

**文件**：`lib/features/chat/engine/markdown_blocks.dart` + `test/markdown_blocks_test.dart`

**API**：
```dart
/// 全量文本 → (已闭合块列表, 尾块)。tail 可为空串。
(List<String> closed, String tail) splitBlocks(String fullText);
```

**切分规则**（TDD 先写测试）：
1. 以空行（`\n\n` 或连续两个换行）切块
2. 遍历时跟踪 ```` ``` ```` fence 开合状态；fence 未闭合时，其后所有内容（含空行）都归入 tail
3. fence 已闭合、且后面还有内容 → 该块闭合
4. `**` 半截、表格半行等行内未完成语法**不影响**块闭合判定（它们天然在 tail 里，因为内容未结束；若它们出现在已闭合块中说明已写完，正常渲染）

**测试用例**（至少覆盖）：
- 单段纯文本 → closed=[], tail=全文
- 两段 `A\n\nB` → closed=[A], tail=B
- ```` ```python\ncode ```` 未闭合 → closed=[], tail=整块
- fence 闭合后跟新段落 → closed=[代码块], tail=新段
- 尾块为空（文本以 `\n\n` 结尾）→ tail=''
- 多个连续空行不产生空块

**验证**：`flutter analyze` 干净；测试逻辑逐条走查（沙箱跑不了 flutter test，node 侧不适用）

## Task 2：StreamingMarkdownRenderer Widget（轨道 A 核心）

**文件**：`lib/features/chat/widgets/markdown_message_view.dart`；`pubspec.yaml` 加 `markdown: ^7.0.0`

**设计**：
```dart
class MarkdownMessageView extends StatefulWidget {
  final String content;   // 全量文本，随 delta 增长
  final TextStyle? baseStyle;
}
```
- `build`：`splitBlocks(content)` → `Column(crossAxisAlignment: start, children: [closed.map(_closedBlock), _tailBlock(tail)])`
- `_closedBlock`：以块文本为 key 查缓存 `Map<String, Widget> _cache`；命中直接复用（closed 块文本永不变化，故缓存永不失效，每条消息一个实例、随消息 Widget 销毁）
- closed 块渲染：`markdown` 包 `markdownToHtml`？**否**——用 `Document().parseNodes()` 拿 AST 节点，映射：`Text`（段落/标题，标题加粗加大）、`` ``` `` 代码块（等宽字体 + 深灰底 Container）、`ul/ol` 列表、行内 `**em**`/`*strong*`/`` `code` `` 简单正则映射 `TextSpan`。链接仅渲染文本 + 协议白名单 http/https
- `_tailBlock`：纯 `Text(tail, style: baseStyle)`，降级显示
- 不渲染任何原始 HTML

**接入**：`chat_bubble.dart:112` 的 `Text(message.content)` → `if (_isAI) MarkdownMessageView(content: message.content) else Text(...)`。气泡 maxWidth 260 保持不变。

**验证**：`flutter analyze lib/` 干净；用一段含代码块+表格+列表的假文本人工走查 splitBlocks 输出与渲染分支（沙箱无 UI，视觉留给 Task 7）

## Task 3：服务端 SSE 透传（轨道 B 服务端）

**文件**：`server/src/services/sse-parse.js` + `server/tests/sse-parse.test.js`；`server/src/services/llm-engine.js` 加函数；`server/src/routes/chat.js`；`index.js` 挂路由

**sse-parse.js**（纯函数，node:test 先行）：
```javascript
// 从上游 DeepSeek SSE chunk 中提取 delta 文本数组。
// 输入可能半包：返回 { deltas: [...], rest: '未成帧尾巴' }
function extractDeltas(chunk, rest) { ... }
```
规则：拼接 rest+chunk → 按 `\n\n` 切帧 → 每帧取 `data: ` 行 → `[DONE]` 标记结束 → JSON 解析 `choices[0].delta.content`。测试：半包拆帧、一 chunk 多帧、非 data 行忽略、[DONE]。

**llm-engine.js 加 `streamChatCompletion(messages, { onDelta, signal })`**：
```javascript
const upstream = await fetch('https://api.deepseek.com/chat/completions', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${apiKey}` },
  body: JSON.stringify({ model: 'deepseek-chat', messages, stream: true, temperature: 0.7, max_tokens: 1024 }),
  signal,
});
// upstream.body 是 Web Stream：for await (const chunk of upstream.body) 逐 Buffer
// Buffer.toString('utf8') + extractDeltas 逐 delta 调 onDelta(text)
// 遇 [DONE] 或流结束 return
```
（system prompt：目标管理助手人设，中文回答，可用 Markdown。）

**routes/chat.js**：
```javascript
router.post('/', async (req, res) => {
  const { messages } = req.body || {};
  if (!Array.isArray(messages) || messages.length === 0) return res.status(400).json({ error: 'messages required' });
  if (!process.env.DEEPSEEK_API_KEY) return res.status(501).json({ error: 'cloud chat not configured' });

  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  });
  const controller = new AbortController();
  req.on('close', () => controller.abort());   // 取消传播：客户端断 → 停上游推理
  try {
    await streamChatCompletion(messages, {
      signal: controller.signal,
      onDelta: (text) => res.write(`data: ${JSON.stringify({ delta: text })}\n\n`),
    });
    res.write('data: [DONE]\n\n');
  } catch (err) {
    if (!controller.signal.aborted) res.write(`data: ${JSON.stringify({ error: err.message })}\n\n`);
  } finally {
    res.end();
  }
});
```
`index.js`：`app.use('/api/chat', require('./routes/chat'));`

**验证**：`npm test`（含新 sse-parse 用例）PASS；`curl -N -X POST localhost:3000/api/chat -H 'Content-Type: application/json' -d '{"messages":[{"role":"user","content":"用 markdown 写个 python hello world"}]}'` 目视逐帧到达 + [DONE] 结尾；Ctrl-C 后服务端日志确认 abort

## Task 4：客户端 SSE 帧解析（轨道 B 客户端地基）

**文件**：`lib/features/chat/engine/sse_parser.dart` + `test/sse_parser_test.dart`

**API**：
```dart
class SseBuffer {
  String _rest = '';
  bool done = false;
  /// 喂入一个解码后的 chunk，返回其中完整帧的 data 内容列表
  List<String> feed(String chunk) { ... }
}
```
规则：`_rest + chunk` → `\n\n` 切帧（残缺留 `_rest`）→ 每帧按行找 `data: ` 前缀 → `[DONE]` 置 `done=true` → 其余原样返回（调用方 JSON 解析 `{delta: ...}`）。帧内 `event:`/`id:`/`retry:` 行忽略。

**测试用例**：帧被拆两半（`'data: {"delta":"你"}\n'` + `'\ndata: {"delta":"好"}\n\n'` 分两次 feed）、一 chunk 含多帧、DONE 之后不再吐、空 chunk。逻辑走查（沙箱跑不了 flutter test）。

## Task 5：CloudChatClient + ChatProvider 双模式接线

**文件**：`lib/features/chat/engine/cloud_chat_client.dart`；`chat_provider.dart` 改造；`pubspec.yaml` 无新增

**CloudChatClient**：
```dart
class CloudChatClient {
  final _dio = Dio(BaseOptions(baseUrl: AppConstants.serverBaseUrl, responseType: ResponseType.stream));
  final _cancel = CancelToken();

  /// 签名与 StrategistPrompter.generateResponse 对齐
  Stream<String> generateResponse(List<({String role, String content})> messages) async* {
    final resp = await _dio.post<ResponseBody>('/api/chat',
      data: {'messages': messages.map((m) => {'role': m.role, 'content': m.content}).toList()},
      cancelToken: _cancel);
    final buffer = SseBuffer();
    await for (final chunk in resp.data!.stream) {           // Stream<Uint8List>
      final text = utf8.decode(chunk, allowMalformed: false); //dio stream 过 utf8：用 stream.transform(utf8.decoder) 更稳，二选一以 analyze 通过为准
      for (final data in buffer.feed(text)) {
        if (buffer.done) return;
        final json = jsonDecode(data) as Map<String, dynamic>;
        final delta = json['delta'] as String?;
        if (delta != null && delta.isNotEmpty) yield delta;
        if (json['error'] != null) throw Exception('云端对话失败: ${json['error']}');
      }
    }
  }

  void stop() => _cancel.cancel();   // → 服务端 req.on('close') → abort 上游
}
```
（utf8 跨 chunk：优先 `resp.data!.stream.cast<List<int>>().transform(utf8.decoder)` 再按字符串 chunk feed，避免多字节汉字被劈开；实现子代理以实测为准。）

**ChatProvider**：
- 构造参数加 `ChatMode mode`（enum `{ local, cloud }`，默认 local）
- `sendMessage`：`Stream<String> stream = mode == cloud ? _cloud.generateResponse(history) : engine.generateResponse(content);` 之后 `await for` 逻辑不变
- 云端模式下不做 seedHistory/上下文截断（端侧专属）；历史窗口取最近 10 条消息随请求发送
- 云端连接失败 → `_error` 提示 + 该轮回退端侧 Mock（与 `loadModel` 失败路径同构）

**验证**：`flutter analyze lib/` 干净；模拟器开服务端后云端模式真发一条消息（Task 7 复核视觉）

## Task 6：停止生成 + 空闲超时 + 设置开关

**文件**：`chat_provider.dart`、`chat_input.dart`（或 chat_page.dart）、`core/repository/settings_repository.dart`、`core/providers/settings_provider.dart`、`features/settings/settings_page.dart`

1. **停止生成**：`sendMessage` 中 `await for` 改为 `final sub = stream.listen(...)`；`stopGeneration()`：`sub.cancel()` + 云端调 `CloudChatClient.stop()`；保留 `buffer` 已有内容写入消息；`finally` 逻辑照旧。`chat_input.dart` 在 `_isThinking` 时把发送按钮换成停止按钮（方块图标）
2. **帧间空闲超时**（仅云端）：包一层 `Stream<String>` 守护——收到 delta 刷新计时器，10s 无新 delta 则抛 `TimeoutException` → 丢弃半截、提示重试（不续传）
3. **设置开关**（三步约定）：`SettingsRepository` 加 `chatCloudMode` key + getter/setter（默认 false，附首次开启隐私说明）；`SettingsProvider` 透传；`SettingsPage` 加 `SwitchListTile`（副标题注明"对话内容将发送至 DeepSeek 云端"）

**验证**：`flutter analyze lib/` 干净；停止生成：模拟器发长问题 → 点停止 → 文字停在已生成处、服务端日志连接断开

## Task 7：端到端验证 + 收尾

1. `cd server && npm test` → 全 PASS（原 4 + sse-parse 新增）
2. `flutter analyze lib/` → 0/0/0
3. `curl -N` `/api/chat` 逐帧 + `[DONE]`（Task 3 已验，复核）
4. 模拟器人工验证清单：
   - 云端模式关（默认）→ 端侧消息出现 Markdown 渲染（发"用 markdown 介绍你自己"看代码块/列表闭合时不闪烁）
   - 云端模式开 → 发消息逐字流式、停止按钮生效、服务端日志无孤儿推理
   - 飞行模式/杀服务端 → 云端模式报错回退，端侧不受影响
5. 更新 daily log；**提交动作留给用户确认**

## 依赖关系

```
Task 1 → Task 2
Task 3（独立，可并行）
Task 4 → Task 5 → Task 6 → Task 7
Task 2、5 完成后 ChatBubble 双通道即可联调
```
