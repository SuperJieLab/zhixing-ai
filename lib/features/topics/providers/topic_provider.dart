import 'package:flutter/foundation.dart';

/// 话题选择的状态管理器
///
/// 这个类是 Provider 状态管理方案的核心 —— 它负责：
/// 1. 存储用户当前选择了哪个话题
/// 2. 当状态变化时，通知所有监听它的 Widget 刷新
///
/// ## 为什么继承 ChangeNotifier？
///
/// ChangeNotifier 是 Flutter 提供的一个「可被监听」的类。
/// 当你调用 [notifyListeners]() 时，所有正在「听」它的 Widget
/// 都会自动重新构建（rebuild），从而更新屏幕上的内容。
///
/// 这和 Provider 包配合使用：
/// ```dart
/// // 在 Widget 树最上层注入
/// ChangeNotifierProvider(create: (_) => TopicProvider())
///
/// // 在任意子 Widget 中读取
/// final provider = context.watch<TopicProvider>();
/// ```
///
/// ## 状态说明
///
/// 用户有两种选话题的方式：
/// - 从 5 个预设中选一个 → 存入 [_selectedTopic]
/// - 自己输入一个话题     → 存入 [_customTopic]
///
/// 这两种方式互斥 —— 选预设会清空自定义，反之亦然。
class TopicProvider extends ChangeNotifier {
  // ============================================================
  // 私有状态（用 _ 开头，外部无法直接访问）
  // ============================================================

  /// 用户选择的预设话题标题
  /// 比如 '职业发展'、'两难决策' 等
  /// null 表示用户还没选
  String? _selectedTopic;

  /// 用户自定义输入的话题
  /// 空字符串 '' 表示用户还没输入
  String _customTopic = '';

  // ============================================================
  // 公开的 getter（只读访问入口）
  // ============================================================

  /// 获取当前选中的预设话题
  /// 返回 null 表示还没选，或者选了自定义话题
  String? get selectedTopic => _selectedTopic;

  /// 获取当前自定义输入的话题文本
  /// 返回空字符串 '' 表示还没输入
  String get customTopic => _customTopic;

  // ============================================================
  // 状态变更方法
  // ============================================================

  /// 用户从 5 个预设话题中选了一个
  ///
  /// 副作用：清空自定义话题（两种选择方式互斥）
  ///
  /// [topic] 是话题的标题，比如 '职业发展'
  void selectTopic(String topic) {
    _selectedTopic = topic;
    _customTopic = ''; // 选了预设，就清空自定义输入
    notifyListeners(); // 告诉所有监听者：「状态变了，请刷新 UI！」
  }

  /// 用户自己输入了一个话题
  ///
  /// 副作用：清空预设话题的选择（两种选择方式互斥）
  ///
  /// [topic] 是用户输入的文本
  void setCustomTopic(String topic) {
    _customTopic = topic;
    _selectedTopic = null; // 选了自定义，就取消预设
    notifyListeners();
  }

  /// 重置所有状态到初始值
  ///
  /// 用于「重新选择」或「返回首页」的场景
  void reset() {
    _selectedTopic = null;
    _customTopic = '';
    notifyListeners();
  }
}
