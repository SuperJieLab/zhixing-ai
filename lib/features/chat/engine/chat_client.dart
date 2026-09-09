import 'package:zhixing_ai/core/models/chat_models.dart';
import 'package:zhixing_ai/core/models/dashboard_models.dart';

/// 对话客户端统一接口
///
/// 本地（llama session）与云端（SSE）双实现共享的最小契约，ChatProvider 只面向
/// 此接口编程，消除模式分支。实现方各自负责：
///   - 本地 [generateResponse] 收完整历史后自行 diff，只把新增消息 append 进
///     llama session（增量 prefill，不整段重放）
///   - 云端自行过滤欢迎语（round==0）并截取窗口，随请求体发送
///
/// 消费方：ChatProvider（唯一），不跨 feature 共享。
abstract class ChatClient {
  /// 引擎是否就绪（本地：initialize 成功；云端：恒 true）。
  /// 未就绪时调用 [generateResponse] 的行为由实现方定义（本地回退文案）。
  bool get isReady;

  /// 就绪引擎。
  ///
  /// [existingGoals] 为 Dashboard 已有目标：本地注入系统提示词（相似目标建议
  /// 合并）；云端暂存（后续 ② 随请求体发送，由服务端拼装）。
  /// 返回 false 表示初始化失败，调用方走降级路径。
  Future<bool> initialize({List<Goal> existingGoals = const []});

  /// 流式生成回复。
  ///
  /// [history] 为完整对话历史（含本轮新用户消息，尾部；含 round==0 欢迎语），
  /// 逐段 yield 回复文本。生成失败经 stream 的 error 事件上抛，由 ChatProvider
  /// 决定降级策略。
  Stream<String> generateResponse(List<ChatMessage> history);

  /// 中断当前进行中的生成（已生成文本的保留策略由 Provider 的订阅取消决定）。
  void stop();

  /// 释放底层资源（ChatProvider.dispose 调用）。
  void dispose();
}
