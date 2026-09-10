import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/data/models/dashboard_models.dart';

/// 对话客户端统一接口：本地（llama session）与云端（SSE）双实现，
/// ChatProvider 只面向此接口，无模式分支。
abstract class ChatClient {
  /// 本地：initialize 成功；云端：恒 true。
  bool get isReady;

  /// 就绪引擎。[existingGoals] 注入系统提示词（goals 上下文）。
  /// 返回 false 表示初始化失败，调用方走降级路径。
  Future<bool> initialize({List<Goal> existingGoals = const []});

  /// 流式生成回复。[history] 为完整历史（尾部为本轮新用户消息，含 round==0 欢迎语），
  /// 逐段 yield 文本；失败经 stream 的 error 事件上抛，由 ChatProvider 决定降级。
  Stream<String> generateResponse(List<ChatMessage> history);

  /// 中断当前生成（已生成文本的保留由 Provider 的订阅取消决定）。
  void stop();

  void dispose();
}
