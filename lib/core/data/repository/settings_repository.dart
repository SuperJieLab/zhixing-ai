import 'package:shared_preferences/shared_preferences.dart';

/// 用户设置持久化（基于 SharedPreferences）
///
/// 目前承载：推理后端选择（GPU 加速 / 纯 CPU）、AI 优化推送开关。
/// 单例，随 App 启动在 [initialize] 中完成预取。
class SettingsRepository {
  static const String _kGpuAcceleration = 'gpu_acceleration_enabled';
  static const String _kAiPush = 'ai_optimized_push';
  static const String _kAiPushConsented = 'ai_push_consented';
  static const String _kCloudChat = 'chat_cloud_mode';
  static const String _kCloudChatConsented = 'chat_cloud_consented';
  static const String _kCloudApiBaseUrl = 'cloud_api_base_url';
  static const String _kCloudApiKey = 'cloud_api_key';
  static const String _kCloudModelName = 'cloud_model_name';

  static final SettingsRepository instance = SettingsRepository._();

  SettingsRepository._();

  late final SharedPreferences _prefs;
  bool _initialized = false;

  /// 必须在 runApp 前 await 调用，完成 SharedPreferences 预取
  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
    _initialized = true;
  }

  /// 是否启用 GPU 加速（Metal 全量卸载）
  ///
  /// true  → gpuLayers = -1（全量卸载到 GPU，真机推理最快）
  /// false → gpuLayers = 0（纯 CPU，跨平台最稳，模拟器可用）
  ///
  /// 默认 false（纯 CPU）：保证模拟器 / 各类环境开箱即用。
  /// 真机用户可在「设置」中开启以获得性能。
  bool get useGpuAcceleration {
    _assertInit();
    return _prefs.getBool(_kGpuAcceleration) ?? false;
  }

  /// 映射为 llama.cpp 的 gpuLayers 参数
  int get gpuLayers => useGpuAcceleration ? -1 : 0;

  Future<void> setUseGpuAcceleration(bool value) async {
    _assertInit();
    await _prefs.setBool(_kGpuAcceleration, value);
  }

  /// 是否启用「AI 优化推送」。
  ///
  /// true  → 服务端用 LLM 模式生成更智能的推送（'mode': 'llm'）
  /// false → 服务端用规则模式（'mode': 'rules'）
  ///
  /// 默认 false（规则模式）：用户需在「设置」中开启。
  bool get useAiOptimizedPush {
    _assertInit();
    return _prefs.getBool(_kAiPush) ?? false;
  }

  Future<void> setUseAiOptimizedPush(bool value) async {
    _assertInit();
    await _prefs.setBool(_kAiPush, value);
  }

  /// 用户是否已同意「AI 优化推送」的隐私说明。
  /// 首次开启时弹窗，同意后持久化，之后不再重复弹。
  bool get aiPushConsented {
    _assertInit();
    return _prefs.getBool(_kAiPushConsented) ?? false;
  }

  Future<void> setAiPushConsented(bool value) async {
    _assertInit();
    await _prefs.setBool(_kAiPushConsented, value);
  }

  /// 是否启用「云端对话模式」。
  ///
  /// true  → 对话内容经服务端转发至 DeepSeek API（离开设备）。
  /// false → 本地 LLM 引擎离线生成（默认，全程不出设备）。
  ///
  /// 默认 false：用户需在「设置」中开启。模式在 [ChatProvider] 构造时读取，
  /// 仅对开启后的新对话生效，不影响正在进行中的对话。
  bool get chatCloudMode {
    _assertInit();
    return _prefs.getBool(_kCloudChat) ?? false;
  }

  Future<void> setChatCloudMode(bool value) async {
    _assertInit();
    await _prefs.setBool(_kCloudChat, value);
  }

  /// 用户是否已同意「云端对话模式」的隐私说明。
  /// 首次开启时弹窗，同意后持久化，之后不再重复弹。
  bool get chatCloudConsented {
    _assertInit();
    return _prefs.getBool(_kCloudChatConsented) ?? false;
  }

  Future<void> setChatCloudConsented(bool value) async {
    _assertInit();
    await _prefs.setBool(_kCloudChatConsented, value);
  }

  // ─── 云端 BYOK 直连配置（三项齐全才允许开启云端模式）───

  /// 模型 API 根地址（如 https://api.deepseek.com，客户端拼 /chat/completions）
  String get cloudApiBaseUrl {
    _assertInit();
    return _prefs.getString(_kCloudApiBaseUrl) ?? '';
  }

  Future<void> setCloudApiBaseUrl(String value) async {
    _assertInit();
    await _prefs.setString(_kCloudApiBaseUrl, value.trim());
  }

  /// 模型 API Key（用户自备，仅存本机 shared_preferences）
  String get cloudApiKey {
    _assertInit();
    return _prefs.getString(_kCloudApiKey) ?? '';
  }

  Future<void> setCloudApiKey(String value) async {
    _assertInit();
    await _prefs.setString(_kCloudApiKey, value.trim());
  }

  /// 模型名（自由文本，如 deepseek-chat；不做厂商枚举）
  String get cloudModelName {
    _assertInit();
    return _prefs.getString(_kCloudModelName) ?? '';
  }

  Future<void> setCloudModelName(String value) async {
    _assertInit();
    await _prefs.setString(_kCloudModelName, value.trim());
  }

  /// BYOK 三件套是否齐全（开启云端模式的前提）。
  bool get isCloudApiConfigured =>
      cloudApiBaseUrl.trim().isNotEmpty &&
      cloudApiKey.trim().isNotEmpty &&
      cloudModelName.trim().isNotEmpty;

  void _assertInit() {
    assert(_initialized, 'SettingsRepository 未初始化，请先调用 initialize()');
  }
}
