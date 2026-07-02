import 'package:flutter/foundation.dart';

/// 一条对话消息
///
/// 每条消息都有三个属性：
/// - [role]：谁说的？'ai' 或 'user'
/// - [content]：说了什么？
/// - [round]：发生在第几轮对话中？
///
/// 使用 const 构造函数，创建后不可变（immutable）。
/// 这避免了消息内容被意外修改导致的 Bug。
class ChatMessage {
  /// 消息角色：'ai'（AI 的追问）或 'user'（用户的回答）
  final String role;

  /// 消息文本内容
  final String content;

  /// 所属的对话轮次
  ///
  /// 欢迎消息为第 1 轮，第一轮用户问答为第 2 轮，以此类推。
  /// 同一轮对话中，用户消息和 AI 回复共享相同的 round 值。
  final int round;

  /// 创建一个不可变的消息实例
  ///
  /// 三个参数都是 required（必须提供），确保每条消息信息完整。
  const ChatMessage({
    required this.role,
    required this.content,
    required this.round,
  });
}

/// 对话状态管理
///
/// 负责管理整个苏格拉底式对话的生命周期：
/// - 生成与话题匹配的欢迎消息（AI 主动开口）
/// - 接收用户输入并生成 Mock AI 追问
/// - 跟踪对话轮次
///
/// ## Mock 回复机制（MVP）
/// 当前使用 5 句预设的苏格拉底式追问，按顺序轮换。
/// Day 3 将替换为连接真实 LLM（通过 dart_llama FFI）。
///
/// ## ChangeNotifier 模式
/// 继承 ChangeNotifier 后，调用 notifyListeners() 会通知
/// 所有监听者（Widget）刷新 UI。这是 Provider 状态管理的核心。
///
/// ## 使用方式
/// ```dart
/// final provider = ChatProvider(topic: '职业发展');
/// print(provider.messages.first.content); // AI 的欢迎消息
/// provider.sendMessage('我想转管理');       // 用户发送消息，AI 自动追问
/// ```
class ChatProvider extends ChangeNotifier {
  /// 对话话题标题
  final String topic;

  /// 当前对话轮次
  ///
  /// _ 前缀表示私有（private），外部只能通过 getter 访问。
  /// 这是 Dart 的封装机制——外部不能直接改 _round，
  /// 只能通过 sendMessage() 间接修改。
  int _round = 1;

  /// 是否正在等待 AI 回复
  ///
  /// MVP 阶段 AI 是 Mock 的（瞬间完成），
  /// 所以这个标志在消息处理完成后立即变回 false。
  /// Day 3 接入真实 LLM 后，会在等待推理期间保持 true。
  bool _isThinking = false;

  /// 对话消息列表（内部存储）
  ///
  /// 外部通过 getter [messages] 获取「不可变视图」，
  /// 防止直接操作列表。
  final List<ChatMessage> _messages = [];

  /// 构造函数
  ///
  /// 创建时会自动调用 _addWelcomeMessage()，
  /// 根据话题生成一条 AI 的欢迎消息。
  ChatProvider({required this.topic}) {
    _addWelcomeMessage();
  }

  // ==============================================================
  // Getters（外部只读访问）
  // ==============================================================

  /// 获取所有消息的不可变列表
  ///
  /// List.unmodifiable() 创建一个不能增删改的列表视图。
  /// 防止外部代码绕过 ChatProvider 直接修改消息列表，
  /// 保证状态变更只通过 sendMessage() 发生。
  List<ChatMessage> get messages => List.unmodifiable(_messages);

  /// 获取当前对话轮次
  int get round => _round;

  /// 获取 AI 是否正在「思考」（等待回复生成）
  bool get isThinking => _isThinking;

  // ==============================================================
  // 公共方法
  // ==============================================================

  /// 用户发送一条消息
  ///
  /// 处理流程：
  /// 1. 把用户消息加入消息列表
  /// 2. 标记"思考中"
  /// 3. 生成 Mock AI 追问（MVP）或等待 LLM 推理（Day 3）
  /// 4. 把 AI 回复加入消息列表
  /// 5. 轮次 +1，标记"思考结束"
  /// 6. 通知所有监听者刷新 UI
  ///
  /// [content]：用户输入的文本内容
  void sendMessage(String content) {
    // 步骤 1：添加用户的消息
    _messages.add(ChatMessage(
      role: 'user',
      content: content,
      round: _round,
    ));

    // 步骤 2：标记 AI 开始思考
    // 注意：MVP 阶段这是瞬间的，但为了完整性保留了状态切换
    _isThinking = true;
    notifyListeners(); // 通知 UI：「AI 在想，显示加载动画」

    // 步骤 3 + 4：生成并添加 AI 回复
    // Day 3 替换：这里会调用 dart_llama FFI 进行真实推理
    _messages.add(ChatMessage(
      role: 'ai',
      content: _generateMockResponse(content),
      round: _round,
    ));

    // 步骤 5：轮次 +1，思考结束
    _round++;
    _isThinking = false;

    // 步骤 6：通知所有监听者
    // Widget 收到通知后会重新调用 build()，用新消息列表渲染
    notifyListeners();
  }

  // ==============================================================
  // 私有方法
  // ==============================================================

  /// 生成与话题匹配的欢迎消息
  ///
  /// 欢迎消息是 AI 发起的第一句追问，目的是：
  /// - 让用户感受到「AI 在追问我」，而不是反过来
  /// - 用开放性问题引导用户思考
  /// - 展示苏格拉底式对话的风格（不说教、不评判）
  void _addWelcomeMessage() {
    // 每个预设话题都有定制的开场白
    // ?? 操作符：如果话题不在表中，使用默认欢迎消息
    const openings = <String, String>{
      '职业发展':
          '你提到想聊聊职业方向——如果三年后的你回头看今天做的选择，你觉得他会在意什么？',
      '两难决策':
          '你面前有两个选择——在做决定之前，你想过这两个选择分别代表了什么样的自己吗？',
      '自我探索':
          '关于"我是谁"这个问题——你最近一次觉得自己不够了解自己，是什么时候？',
      '工作难题':
          '这个问题卡住了你——你觉得卡住的到底是事情本身，还是你看待事情的角度？',
      '人际关系':
          '这段关系让你在意的地方是什么——是对方的期待，还是你对自己在这段关系里的要求？',
    };

    // 取对应话题的开场白，没有的话用默认消息
    final opening = openings[topic] ?? '你想和我聊聊什么话题？让我们从头开始。';

    // 添加 AI 欢迎消息（第 1 轮）
    _messages.add(ChatMessage(
      role: 'ai',
      content: opening,
      round: _round,
    ));

    // 注意：欢迎消息不递增 _round
    // _round 代表「当前轮次」，sendMessage() 在 AI 回复后才会递增
  }

  /// 生成 Mock AI 回复
  ///
  /// MVP 阶段使用 5 句预设的苏格拉底式追问，按索引轮换。
  /// 轮换逻辑：用当前消息数量对 5 取模，
  /// 保证连续追问不重复（但会在 5 轮后循环）。
  ///
  /// [userInput]：用户输入文本（当前未被使用，Day 3 LLM 推理时使用）
  /// 返回：一条苏格拉底式追问
  String _generateMockResponse(String userInput) {
    // 5 句预设追问，全部是开放式问题
    // 设计原则：
    // - 不带预设答案（不暗示"你应该...")
    // - 引导用户审视自己的思考过程
    // - 用具体问题而非抽象哲学
    const responses = [
      '你提到的这点很有意思——你能给我一个具体的例子吗？',
      '如果完全没有失败的风险，你的答案会变吗？',
      '你刚才说到的这个想法，背后最让你担心的是什么？',
      '换句话说，你觉得这件事对你来说最重要的是什么？',
      '如果一位朋友处在你的位置，你给他什么建议？',
    ];

    // 用消息数量对 5 取模，循环轮换
    return responses[_messages.length % responses.length];
  }
}
