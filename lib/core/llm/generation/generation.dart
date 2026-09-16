import 'package:zhixing_ai/core/context/context_assembly.dart';

/// 交付段（基建）：**把装配好的输入上下文交给模型执行的那一步**。
///
/// 这是双端唯一的形状差异：
/// - 云端 = 数据**进请求**（`messages: [...]` 一次性无状态）；
/// - 端侧 = 数据**进对象**（llama 没有「发送消息」API，只能把消息推进活着的
///   会话对象再 generate）。
///
/// 具体后端差异只允许出现在本接口的实现里（新增第三个后端只改基建文件）。
/// 交付实现**不持业务语义状态**：历史由服务每轮传入，人设由业务经
/// `systemPrompt` 提供。
abstract class ChatGeneration {
  /// 当前是否就绪（端侧=会话已创建；云端=恒 true）。
  bool get isReady;

  /// 确保就绪（幂等）：端侧创建推理会话，云端无操作。
  /// 失败抛带语义的异常，由服务/业务决定降级。
  Future<void> ensureReady();

  /// 交付并流式取回文本（think 剥离策略由各实现决定）。
  Stream<String> deliver(
    AssembledContext assembled, {
    required String systemPrompt,
    bool nudgeTail = true,
  });

  /// **仅预置、不生成**：端侧把装配结果重放进会话（供溢出收缩后的下一轮直接
  /// 可用）；云端无会话态 → 空实现（契约对称）。
  void prime(
    AssembledContext assembled, {
    required String systemPrompt,
    bool nudgeTail = true,
  });

  /// 中断进行中的流。
  void stop();

  void dispose();
}

/// 端侧 `context full` 的类型化信号（本地交付抛出、服务承接）。
///
/// 抛出即代表「真实上下文先于估算撑爆」：服务收到后强制收缩 → 重新装配 →
/// 预置会话，使下一轮直接可用；本轮以 [kLlmFailureReply] 收尾。
class LlmContextOverflowException implements Exception {
  const LlmContextOverflowException();

  @override
  String toString() => 'LlmContextOverflowException（端侧上下文已撑爆）';
}

/// 生成彻底失败时的兜底文案（原 `LocalChatClient` 的固定提示，用户可见）。
const String kLlmFailureReply = '\n\n[助手暂时无法回应，请稍后再试]';

/// 引擎尚未就绪时的回退文案（原 `LocalChatClient` 行为）。
const String kLlmNotReadyReply = '助手尚在准备中，请稍后再来。';

/// 本轮生成正常结束但无任何可见正文时的兜底文案。
///
/// 典型成因：模型把生成上限全部消耗在思考段里且未输出闭合标签
/// （`<think>` 开头、无 `</think>`）——过滤层整轮静默、`flush` 也无正文。
/// 静默空气泡比报错更伤体验，故交付实现必须在此收口。
const String kLlmEmptyReply = '（本轮思考未能收敛为正文，请重试或换个问法）';
