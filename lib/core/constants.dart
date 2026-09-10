/// 应用常量与预设数据
///
/// 存放不会在运行时变化的静态数据，比如 LLM 模型配置、服务端地址等。
class AppConstants {
  // ─── LLM 模型配置 ───

  /// 模型上下文窗口（token）
  static const int modelContextSize = 4096;

  /// GPU 层数（兜底默认值）：-1 = 全部卸载到 GPU（Metal），0 = 纯 CPU
  ///
  /// ⚠️ 实际值已由「设置」决定：[LlamaService.ensureReady] 的调用方
  /// 传入 [SettingsRepository.gpuLayers]（用户开关，默认 0 = 纯 CPU）。
  /// 此处常量仅作为仓库不可用时的兜底，勿直接依赖。
  static const int modelGpuLayers = 0;

  /// CPU 推理线程数
  static const int modelThreads = 4;

  /// 单次生成 token 上限（本地对话 / 服务端云端回复 / 结构化提取 共用）。
  /// 服务端 llm-engine.js 的 max_tokens 与此对齐。
  static const int modelMaxTokens = 2048;

  /// 输入上下文安全余量（chat template 包装开销 + token 估算误差）
  static const int contextMargin = 384;

  /// 输入侧安全 token 预算 = nCtx − 生成上限 − 余量。
  /// 所有喂给模型的历史/上下文都应以此封顶，保证「预算内输入 + 一整轮生成」仍在窗口内。
  static int get contextInputBudget =>
      modelContextSize - modelMaxTokens - contextMargin;

  /// 默认模型路径（运行时由下载系统动态设置）
  /// 初始为空字符串，表示尚未下载任何模型。
  /// 下载完成后 [ModelDownloadProvider] 会将其设为沙盒路径。
  static String defaultModelPath = '';

  // ─── 模型下载 ───

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

