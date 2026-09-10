# 知行AI — 云端模型 BYOK 直连 + 服务端对话链路退场

> 状态：设计已确认（2026-09-10 对话确认，三个决策点用户已拍板：BYOK 直连不做厂商枚举；服务端对话链路删除、只留业务接口；模型参数 MVP 不下发、用厂商默认）
> 背景：端上可配自定义远端模型（自带 key + url），替代现「服务端持 key 转发 DeepSeek」的固定通道

## 1. 背景与动机

现状：云端对话经服务端 `/api/chat` 转发，`model: deepseek-chat` 与服务端 `DEEPSEEK_API_KEY` 硬编码在服务端。问题：模型/厂商写死；换厂商要改服务端代码。

两个候选架构（2026-09-10 讨论）：

| 维度 | A. 端侧直连（选定） | B. 仍经服务端转发 |
|---|---|---|
| Key 链路 | 手机 → 模型厂商，仅 TLS | key 每请求过我们的服务器（日志/泄露面变大） |
| 服务端依赖 | **零**——服务端挂了云端对话照常用 | 聊天强依赖服务端在线 |
| 推送 cron（服务端自己的 key） | 两种方案下都一样，不受影响 | 同左 |
| 客户端改动 | 加 OpenAI delta 解析（`SseBuffer` 等基建复用） | 零改动（服务端转自定义帧） |
| 厂商适配 | 任何 OpenAI 兼容端点直接可用 | 服务端写「转发到任意 url」的哑代理 |

**选定 A**：B 的唯一净收益（客户端解析零改动）不值 key 过服务器 + 强服务端依赖的代价。

连带推论（用户拍板）：`/api/chat` 转发链路存在的唯一前提「端上没有凭据」已消失，**随直连一并删除**——服务端收敛为纯业务后端（同步 / 推送 / 推送决策），不再参与对话。

## 2. 已确认的决策

| 决策点 | 结论 |
|---|---|
| **连接架构** | 端侧直连用户配置的 OpenAI 兼容端点；服务端对话链路（`/api/chat` + `streamChatCompletion`）删除 |
| **可配范围** | BYOK 三件套：`baseUrl` + `apiKey` + `modelName`，自由文本，**不做厂商枚举** |
| **模型参数** | MVP 不下发（temperature/top_p/max_tokens 等全部省略，用厂商默认）。「先做基础可配」——想调时再加，单处改动 |
| **未配置的云端模式** | 设置层门禁：三件套不全不允许开启云端模式（开启开关时校验并引导补配置） |
| **运行时失败** | 直连失败（网络/401/超时）→ 现有降级链不变：TimeoutException 提示重试 / 无产出降级 Mock |
| **凭据存储** | MVP `shared_preferences` 明文（个人设备风险同级）；Keychain（flutter_secure_storage）为后续候选 |
| **协议约束** | 仅支持 OpenAI 兼容 `/chat/completions`（事实标准，覆盖 DeepSeek/Moonshot/OpenRouter/DS 兼容模式/Ollama/one-api 网关）；iOS ATS 限制实际上要求 https |
| **systemPrompt** | 直连放 `messages[0]`（标准 OpenAI 格式）；人设唯一出处 `ConversationStrategy` 原样复用。服务端透传逻辑随 `/api/chat` 删除（候选②的透传机制退役，但对等性原则落地更彻底） |

## 3. 直连协议设计

### 3.1 请求

```
POST {baseUrl}/chat/completions
Authorization: Bearer {apiKey}
Content-Type: application/json

{
  "model": "{modelName}",
  "messages": [
    { "role": "system", "content": <ConversationStrategy.buildSystemPrompt(existingGoals)> },
    ...窗口消息（round==0 过滤 + 尾部 10 条，现有窗口逻辑原样保留）
  ],
  "stream": true
}
```

- `baseUrl` 存「根地址」形态（如 `https://api.deepseek.com`），客户端拼 `/chat/completions`——与用户在厂商文档看到的一致，少一个出错点
- Dio `BaseUrl` 动态：`_dio.post` 用完整 url 或每次重建 Dio；实现取「请求级完整 url」

### 3.2 响应解析

- `SseBuffer` **零改动复用**：OpenAI SSE 同为 `data: {...}\n\n` + `data: [DONE]`，缓冲状态机的归一化/残帧/粘性 done 语义完全匹配
- delta 提取从 `json['delta']` 改为 `json['choices'][0]['delta']['content']`（缺失/空跳过；`finish_reason` 等字段忽略）
- 自定义 `error` 帧随 `/api/chat` 消失：失败语义改为 **HTTP 非 200 → 抛错**（含 status code，401/429 等用户可读）；流中 JSON 解析失败照旧 `_safeError`

### 3.3 stop / 超时 / 取消

- 机制原样：`CancelToken`（中断建连/首字节）+ 响应体订阅 cancel（中断进行中的流）+ 帧间空闲超时 10s
- 语义变化：停止生成 = 客户端直接断 socket，厂商按 OpenAI 规范计费到中断点——不再有服务端 `res.close → abort 上游` 中继

## 4. 服务端瘦身清单

| 对象 | 处置 | 说明 |
|---|---|---|
| `routes/chat.js`（整个路由） | **删** | index.js 摘除挂载 |
| `llm-engine.streamChatCompletion` | **删** | 聊天转发唯一使用方是 chat 路由 |
| `llm-engine.CHAT_SYSTEM_PROMPT` | **删** | 兜底人设随转发链路退役 |
| `services/sse-parse.js` + 其测试 | **删** | `extractDeltas` 仅被 streamChatCompletion 使用，连带死代码 |
| `tests/chat-route.test.js` | **删** | |
| `llm-engine.analyzePushDecision` | **保留** | 推送决策是服务端自己的业务推理（cron 用），与端上配置无关；注意其 URL 硬编码 `api.deepseek.com` 不走 `DEEPSEEK_BASE_URL`，需确认 push 测试 mock 机制不受删改影响 |
| `DEEPSEEK_BASE_URL` 常量/导出 | 视 push 测试依赖决定（若无消费方则删） | |
| `/api/sync`、`/ws`、`/api/debug-push` | 不动 | 纯业务 |

## 5. 设置层设计

- `SettingsRepository` 新增：`cloudApiBaseUrl` / `cloudApiKey` / `cloudModelName`（String，默认空）+ 派生 getter `isCloudApiConfigured`（三项 trim 后均非空）
- `SettingsProvider` 按既有三步曲透传
- `SettingsPage` 云端模式区改造：
  - 云端模式开关下新增配置区（三项 `TextField`：API 地址 / API Key（`obscureText` 遮罩）/ 模型名），placeholder 给 DeepSeek 示例
  - 开启云端模式时若 `!isCloudApiConfigured` → 弹窗提示先补全配置，不置位开关（既有 consent 弹窗在其后照常走）
  - 文案修正：去掉「经服务端转发至 DeepSeek」→「直连你配置的模型 API」；consent 弹窗同步（对话内容发送至你配置的服务商，不经过本应用服务端）
- 配置修改「下次新对话生效」语义与现有模式切换一致（ChatProvider 构造/工厂时读取）

## 6. Task 划分（详见 plan）

1. 服务端瘦身（删转发链路，独立可提交，服务端先行）
2. 配置三件套（SettingsRepository + Provider + SettingsPage 门禁）
3. `CloudChatClient` 直连改造 + ChatProvider 接线
4. 收尾（全量回归 / MEMORY / 冒烟项）

依赖：Task 1 与 Task 2/3 无代码依赖（客户端测试用本地 mock，不碰真实服务端），按此顺序纯为提交节奏清晰。

## 7. 范围外（明确不做）

- 模型参数（temperature/max_tokens 等）端上可配——后续按需加
- Keychain 安全存储
- 非 OpenAI 兼容协议（如 Anthropic messages 格式、Gemini）
- 端侧 GGUF 模型文件自定义导入 + 端侧模型参数可配（独立迭代）
- `GET /api/models` 类厂商注册表（被 BYOK 取代，永不做的备选记档）
- 多配置 profile（同时存多套 key 切换）

## 8. 测试策略

| 对象 | 方式 |
|---|---|
| `SseBuffer` | 零改动，既有 8 用例回归即可（OpenAI 帧格式兼容性由 E2E mock 覆盖） |
| CloudChatClient 直连 | 既有 mock HttpServer 基建复用，响应帧改 OpenAI 格式：正常流/stop 断开感知/空闲超时/窗口构造/裁剪 五用例语义保留；新增：非 200（401）→ 抛错可读、`delta.content` 缺失帧跳过、请求体含 system+model+Authorization 断言 |
| 设置门禁 | 三件套不全 → 开关不置位；全配 → 正常开启；`isCloudApiConfigured` 派生逻辑单测 |
| ChatProvider | cloud 模式 + 未配置 → 工厂抛错 → 降级 Mock + modelError（现有 catch 链） |
| 服务端 | 删 chat-route/sse-parse 测试；`npm test` 全绿；push 测试确认无波及 |
| 回归 | `flutter analyze` 0 + 全量 `flutter test` 绿 |

## 9. 风险与边界

- **厂商行为差异**：部分兼容端点的 delta 可能含 `reasoning_content` 等额外字段——只取 `delta.content`，未知字段忽略即可；个别网关不发 `[DONE]` 而直接关流 → onDone 正常收尾（SseBuffer 粘性 done 只是提前截断，不依赖）
- **Key 明文**：shared_preferences 可被越狱/备份读取，个人设备接受；文档标注后续 Keychain 候选
- **用户误配**：url 带尾斜杠 / 已含 `/v1` 等——MVP 不做智能纠正，报错信息透传 status 帮助定位；placeholder 引导正确形态
- **401/欠费**：非 200 抛错文案含 status，降级 Mock 照旧，用户可从 modelError 看到原因
