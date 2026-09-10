/// 应用常量与预设数据
class AppConstants {
  // ─── 本地端侧模型（llama.cpp + Qwen）───
  //
  // 以下参数全部描述**端侧 2B 模型**的约束。云端模型（DeepSeek）能力独立，
  // 其输出上限等限制由 server/src/services/llm-engine.js 自行定义，
  // 不要跨端共享——两端约束来源不同（nCtx 窗口 vs API 配额）。

  /// 端侧上下文窗口（token）
  static const int localContextSize = 4096;

  /// 端侧单次生成 token 上限
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

  /// 默认模型路径（运行时由下载系统动态设置）
  /// 初始为空字符串，表示尚未下载任何模型。
  /// 下载完成后 [ModelDownloadProvider] 会将其设为沙盒路径。
  static String defaultModelPath = '';

  /// 沙盒内模型存储子目录
  static const String modelSubDir = 'models';

  // ─── 服务端地址（HTTP 与 WS 共用）───

  /// 服务端基地址（HTTP 与 WS 共用）。
  /// 默认 localhost，适合 iOS 模拟器；真机联调改为 Mac 局域网 IP（如 http://192.168.x.x:3000）。
  /// 端口须与服务端 server/src/index.js 的 PORT（默认 3000，.env 可覆盖）一致。
  static const String serverBaseUrl = 'http://localhost:3000';

  /// WS 地址：把 http:// 换成 ws://（https:// → wss://）
  static String get serverWsUrl =>
      serverBaseUrl.replaceFirst('http://', 'ws://').replaceFirst('https://', 'wss://');
}
