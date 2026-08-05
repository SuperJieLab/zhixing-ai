import 'dart:io';

/// 应用常量与预设数据
///
/// 存放不会在运行时变化的静态数据，比如 App 名称、LLM 模型配置等。
class AppConstants {
  /// 应用名称 — 显示在 AppBar、启动屏等位置
  static const String appName = '知行AI';

  /// 应用标语 — 一句话说明这个 App 是做什么的
  static const String appTagline = '帮你想清楚';

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

  /// 默认模型路径（运行时由下载系统动态设置）
  /// 初始为空字符串，表示尚未下载任何模型。
  /// 下载完成后 [ModelDownloadProvider] 会将其设为沙盒路径。
  static String defaultModelPath = '';

  // ─── 模型下载 ───

  /// 沙盒内模型存储子目录
  static const String modelSubDir = 'models';

  /// 检查当前 [defaultModelPath] 指向的模型文件是否存在
  static bool isModelAvailable() {
    return defaultModelPath.isNotEmpty && File(defaultModelPath).existsSync();
  }

  // ─── 服务端地址（HTTP 与 WS 共用）───

  /// 服务端基地址（HTTP 与 WS 共用）。
  /// 默认 localhost，适合 iOS 模拟器；真机联调改为 Mac 局域网 IP（如 http://192.168.x.x:3000）。
  static const String serverBaseUrl = 'http://localhost:3000';

  /// WS 地址：把 http:// 换成 ws://（https:// → wss://）
  static String get serverWsUrl =>
      serverBaseUrl.replaceFirst('http://', 'ws://').replaceFirst('https://', 'wss://');
}

