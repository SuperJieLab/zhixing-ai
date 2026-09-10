/// 对话消息角色
///
/// 替代原先的魔法字符串 'ai' / 'user'，
/// 提供编译期类型安全，防止拼写错误导致的静默 Bug。
enum MessageRole {
  /// AI 发出的消息（追问）
  ai,

  /// 用户发出的消息（回答）
  user,
}

/// 一条对话消息
///
/// 每条消息都有三个属性：
/// - [role]：谁说的？（ai 或 user）
/// - [content]：说了什么？
/// - [round]：发生在第几轮对话中？
///
/// 使用 const 构造函数，创建后不可变（immutable）。
/// 这避免了消息内容被意外修改导致的 Bug。
class ChatMessage {
  /// 消息角色
  final MessageRole role;

  /// 消息文本内容
  final String content;

  /// 所属的对话轮次
  ///
  /// 欢迎消息为第 0 轮（序言），第一轮用户问答为第 1 轮，
  /// 以此类推。同一轮对话中，用户消息和 AI 回复共享相同的 round 值。
  final int round;

  /// 创建一个不可变的消息实例
  const ChatMessage({
    required this.role,
    required this.content,
    required this.round,
  });
}
