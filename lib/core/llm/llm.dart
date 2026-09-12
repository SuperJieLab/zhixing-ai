/// 大模型服务的业务依赖面（唯一）。
///
/// 业务只认这个接口——后端（本地 / 云端）差异全部关进 `core/llm`，
/// 模式由服务按用户设置解析（唯一解析点），业务不感知「当前用的谁」。
///
/// `converse`（多轮对话流）与 `stop` 在 Task 3（对话链路并入）加入；
/// 本 Task 只落单次补全能力。
library;

/// 推理后端模式。
///
/// 全 App 只有两种状态（本地 / 云端），由一份用户配置决定；
/// 所有业务场景跟随同一份配置（提取与对话同源，见设计文档 §2 决策 1）。
enum ChatMode {
  local,
  cloud,
}

/// 大模型服务接口：单次补全 + 结构化补全 + 就绪态。
abstract class Llm {
  /// 一次补全：给 system + user，回一段文本（内部收流、剥 think）。
  ///
  /// [maxTokens] 缺省时用后端默认值。后端未就绪时由入口自行确保
  /// （本地加载模型 / 云端校验配置），失败抛带语义的异常。
  Future<String> ask({
    required String system,
    required String user,
    int? maxTokens,
  });

  /// 一次补全的**结构化输出契约**：
  /// 内部施加 JSON-only 约束 → 剥 think / 围栏 → 刮首段 `{...}` → `jsonDecode`。
  ///
  /// 返回 null = 模型没能给出可解析 JSON（调用方按「无内容」处理）；
  /// 请求失败仍抛异常（与 [ask] 一致）。容错逻辑只在这里出现一次，双后端共用。
  Future<Map<String, dynamic>?> askJson({
    required String system,
    required String user,
    int? maxTokens,
  });

  /// 当前后端是否就绪（供 UI 表达，**不暴露**「本地/云端」）。
  bool get isReady;
}
