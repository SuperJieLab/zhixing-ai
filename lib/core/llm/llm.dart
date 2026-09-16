/// 大模型服务的基建接缝接口（**业务不可见**：业务唯一门面是
/// `core/model_gateway.dart` 的 `ModelGateway`）。
///
/// 职责收窄为「无状态补全面 + 就绪态 + 中断」；多轮对话编排（装配 /
/// 压缩 / 溢出自愈）已上移门面（design D1/D2）。
library;

import 'package:flutter/foundation.dart';

/// 推理后端模式。
///
/// 全 App 只有两种状态（本地 / 云端），由一份用户配置决定；
/// 所有业务场景跟随同一份配置（提取与对话同源，见设计文档 §2 决策 1）。
enum ChatMode {
  local,
  cloud,
}

/// 后端就绪阶段（design §9 #5：由服务表达，UI 只消费）。
///
/// **不暴露**「本地 / 云端」的种类差异——页面据此表达 loading / 错误视图，
/// 与后端是哪种完全无关。
enum LlmPhase {
  /// 尚未确保就绪（服务刚构造 / 尚无任何 ensure 动作）。
  idle,

  /// 就绪化进行中（端侧引擎加载，约 15 秒量级；云端瞬时）。
  loading,

  /// 当前模式所需后端已就绪。
  ready,

  /// 就绪化失败（模型缺失 / 云端 BYOK 未配齐等），[LlmReadiness.error] 带语义。
  failed,
}

/// 就绪状态快照（[Llm.readiness] 的值类型）。
@immutable
class LlmReadiness {
  final LlmPhase phase;

  /// 失败原因（仅 [LlmPhase.failed] 时有意义；展示用 `toString()`）。
  final Object? error;

  const LlmReadiness.idle() : phase = LlmPhase.idle, error = null;
  const LlmReadiness.loading() : phase = LlmPhase.loading, error = null;
  const LlmReadiness.ready() : phase = LlmPhase.ready, error = null;
  const LlmReadiness.failed(this.error) : phase = LlmPhase.failed;

  @override
  bool operator ==(Object other) =>
      other is LlmReadiness &&
      other.phase == phase &&
      other.error?.toString() == error?.toString();

  @override
  int get hashCode => Object.hash(phase, error?.toString());

  @override
  String toString() => 'LlmReadiness($phase, error: $error)';
}

/// 单次补全的函数形态（后端接缝）：`LlmService` 按模式把 `ask` 委派给其一。
///
/// 测试注入 fake 即可覆盖模式路由与解析容错，无需真实引擎 / 网络。
/// （原 `single_shot_summarizer.dart` 定义，T7 迁入接口文件。）
typedef SingleShotAsk = Future<String> Function({
  required String system,
  required String user,
  int? maxTokens,
});

/// 大模型服务基建接口：单次补全 + 结构化补全 + 就绪态 + 中断。
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

  /// 确保当前后端就绪（幂等）：本地加载引擎 + 建会话，云端校验 BYOK 配置。
  /// 失败抛带语义的异常（业务据此走降级 / 错误视图）。
  Future<void> ensureReady();

  /// 中断进行中的对话流。
  void stop();

  /// 当前后端是否就绪（供 UI 表达，**不暴露**「本地/云端」）。
  bool get isReady;

  /// 就绪态（可监听）：[isReady] 的时间维版本。
  ///
  /// 服务在冷启动预热 / [ensureReady] / 用户切换模式时更新；
  /// UI 据此表达 loading / 错误视图并触发兜底加载，不感知后端种类。
  ValueListenable<LlmReadiness> get readiness;
}

