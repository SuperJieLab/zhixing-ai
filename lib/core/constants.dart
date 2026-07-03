/// 应用常量与预设数据
///
/// 存放不会在运行时变化的静态数据，比如 App 名称、
/// 5 个预设话题等。这些数据在编译时就确定了，
/// 所以用 static const 定义。
class AppConstants {
  /// 应用名称 — 显示在 AppBar、启动屏等位置
  static const String appName = 'Socratic AI';

  /// 应用标语 — 一句话说明这个 App 是做什么的
  static const String appTagline = '帮你想清楚';

  // ─── LLM 模型配置 ───

  /// GGUF 模型文件名（当前使用 Qwen3.5-2B）
  static const String modelFileName = 'qwen3.5-2b-q4_k_m.gguf';

  /// 模型上下文窗口（token）
  static const int modelContextSize = 2048;

  /// GPU 层数：-1 = 全部卸载到 GPU（Metal），0 = 纯 CPU
  static const int modelGpuLayers = -1;

  /// CPU 推理线程数
  static const int modelThreads = 4;

  /// macOS 开发环境下的 libllama.dylib 路径
  /// 生产环境请使用 [LlamaService.loadModelFromProcess]
  static const String macosLibPath =
      'macos/Runner/libs/libllama.dylib';

  /// macOS 开发环境下的 GGUF 模型绝对路径
  static const String macosDevModelPath =
      'assets/models/qwen3.5-2b-q4_k_m.gguf';

  // ─── 预设话题 ───
  ///
  /// 用户打开 App 时看到的 5 张话题卡片。
  /// 每个话题由图标（emoji）、标题、描述组成。
  /// 这些话题覆盖了常见的深度对话场景，
  /// 目的是让用户快速开始，降低决策成本。
  static const List<TopicItem> presetTopics = [
    TopicItem(
      icon: '🧭', // 指南针 — 暗示方向选择
      title: '职业发展',
      description: '该深耕还是该转型？',
    ),
    TopicItem(
      icon: '💭', // 思考气泡 — 暗示权衡
      title: '两难决策',
      description: '两个选项，怎么选？',
    ),
    TopicItem(
      icon: '🧠', // 大脑 — 暗示自我认知
      title: '自我探索',
      description: '我想成为什么样的人？',
    ),
    TopicItem(
      icon: '💼', // 公文包 — 暗示职场
      title: '工作难题',
      description: '这个问题到底卡在哪？',
    ),
    TopicItem(
      icon: '❤️', // 心 — 暗示情感
      title: '人际关系',
      description: '这段关系我该怎么看？',
    ),
  ];
}

/// 话题数据模型
///
/// 一个简单的「数据类」（data class），只包含属性，不包含行为。
/// 使用 const 构造函数，意味着创建后不可修改（immutable），
/// 这有助于避免意外的数据变更，也方便 Flutter 的 Widget 做性能优化比较。
///
/// 字段说明：
/// - [icon]：话题的图标，使用 emoji 字符串（如 '🧭'）
/// - [title]：话题的标题，通常 4 个字以内
/// - [description]：话题的描述，一句话说明这个话题适合什么场景
class TopicItem {
  /// 话题图标（emoji 字符串）
  final String icon;

  /// 话题标题
  final String title;

  /// 话题描述
  final String description;

  /// 构造函数
  ///
  /// const 表示这个对象可以在编译时就创建好，运行时不可变。
  /// required 表示这三个参数必须提供，缺一不可。
  const TopicItem({
    required this.icon,
    required this.title,
    required this.description,
  });
}
