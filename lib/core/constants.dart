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

  /// GPU 层数：-1 = 全部卸载到 GPU（Metal），0 = 纯 CPU
  static const int modelGpuLayers = -1;

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
}

