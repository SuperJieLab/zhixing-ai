/// 大模型服务的业务依赖面（唯一）。
///
/// 业务只认这个接口——后端（本地 / 云端）差异全部关进 `core/llm`，
/// 模式由服务按用户设置解析（唯一解析点），业务不感知「当前用的谁」。
library;

import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/llm/context_assembly.dart';

/// 推理后端模式。
///
/// 全 App 只有两种状态（本地 / 云端），由一份用户配置决定；
/// 所有业务场景跟随同一份配置（提取与对话同源，见设计文档 §2 决策 1）。
enum ChatMode {
  local,
  cloud,
}

/// 大模型服务接口：多轮对话 + 单次补全 + 结构化补全 + 就绪态。
abstract class Llm {
  /// 一轮对话：给**完整历史**（尾部为本轮新用户消息），回文本流。
  ///
  /// [systemPrompt] 为业务提供的人设（唯一出处是业务侧，基建不持）；
  /// [state] 为业务持有的会话压缩状态实例（类型在基建、实例在业务），
  /// 装配过程就地更新它——**服务不持消息列表、不持压缩状态**。
  ///
  /// 端侧溢出（context full）由服务内部自愈；彻底失败以兜底文案收尾，
  /// 云端异常（超时 / 非 2xx）原样经流上抛，由业务决定降级。
  Stream<String> converse(
    List<ChatMessage> history, {
    required String systemPrompt,
    required ContextState state,
  });

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
}

