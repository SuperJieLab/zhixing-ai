/// 应用常量与预设数据
class AppConstants {
  // ─── 本地端侧模型（llama.cpp + Qwen）───
  //
  // 以下参数全部描述**端侧 2B 模型**的约束。云端模型（DeepSeek）能力独立，
  // 其输出上限等限制由 server/src/services/llm-engine.js 自行定义，
  // 不要跨端共享——两端约束来源不同（nCtx 窗口 vs API 配额）。

  /// 端侧上下文窗口（token）
  ///
  /// KV cache 在创建 context 时按此值一次性分配（静态预付，与实际用量无关）；
  /// 2B Q4 权重 ~2GB，8192 的 KV 仅几十 MB 量级，预付代价可忽略——
  /// 实际占用仍由软件压缩线（[localInputBudget]）控制，配大只是抬高天花板。
  static const int localContextSize = 8192;

  /// 端侧单次生成 token 上限
  ///
  /// ⚠️ 该额度由「思考段」与「可见正文」**共用**——思考越长，正文越短，
  /// 触顶即「写到一半停住」。成因是 llama.cpp 的 ChatML 渲染按
  /// `<|start_header_id|>` / `<|im_start|>` 子串路由，**整段绕过 Qwen 的 Jinja
  /// 模板**（见依赖 `llama_cpp_dart` 的 `known_templates.dart` 注释）：官方
  /// `enable_thinking` 开关与非思考模式的空思考块都不会被注入，模型处于
  /// 「无引导」状态、可能自发思考。
  ///
  /// **不要靠加大本值规避**：这只把触顶推后，不改变「思考侵占正文」的事实。
  /// 占比由 `LocalGeneration` 的日志观测（思考字数 / 正文字数 / 首字延迟）。
  static const int localMaxTokens = 2048;

  /// 端侧输入安全余量：chat template 包装开销 + token 估算误差
  static const int localContextMargin = 384;

  /// 端侧输入侧安全预算 = nCtx − 生成上限 − 余量。
  /// 所有喂给端侧模型的历史/上下文都应以此封顶，
  /// 保证「预算内输入 + 一整轮生成」仍在窗口内。
  static int get localInputBudget =>
      localContextSize - localMaxTokens - localContextMargin;

  /// GPU 层数（兜底默认值）：-1 = 全部卸载到 GPU（Metal），0 = 纯 CPU
  ///
  /// ⚠️ 实际值已由「设置」决定：[LlamaService.ensureReady] 的调用方
  /// 传入 [SettingsRepository.gpuLayers]（用户开关，默认 0 = 纯 CPU）。
  /// 此处常量仅作为仓库不可用时的兜底，勿直接依赖。
  static const int localGpuLayers = 0;

  /// 端侧 CPU 推理线程数
  static const int localThreads = 4;

  /// 沙盒内模型存储子目录
  static const String modelSubDir = 'models';

  // ─── 云端（BYOK）输入预算 ───
  //
  // 云端约束来自「用户所选模型的上下文窗口」，本应用无法预知，故单位取
  // **字符数近似**（各厂商 tokenizer 不同，本地精确估算是伪精确），预算设得
  // 远大于常见对话长度——正常对话不触发装窗/摘要，机制仅作超长对话的兜底。
  //
  // 量级参考（粗估）：60k 字符 ≈ 英文 ~15k token / 中文 ~40k token。
  // 取值偏保守，以免常见 32k 上下文模型在纯中文长对话下触顶（云端无
  // 「context full」这类自愈路径，超限即端点报错）。需要时按所用模型调整。
  static const int cloudInputBudget = 60000;

  // ─── 服务端地址（HTTP 与 WS 共用）───

  /// 服务端基地址（HTTP 与 WS 共用）。
  /// 默认 localhost，适合 iOS 模拟器；真机联调改为 Mac 局域网 IP（如 http://192.168.x.x:3000）。
  /// 端口须与服务端 server/src/index.js 的 PORT（默认 3000，.env 可覆盖）一致。
  static const String serverBaseUrl = 'http://localhost:3000';

  /// WS 地址：把 http:// 换成 ws://（https:// → wss://）
  static String get serverWsUrl =>
      serverBaseUrl.replaceFirst('http://', 'ws://').replaceFirst('https://', 'wss://');
}
