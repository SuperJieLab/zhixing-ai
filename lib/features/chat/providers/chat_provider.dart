import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/engine/dialogue_engine.dart';
import '../../../core/models/chat_models.dart';

/// 对话状态管理
///
/// 负责管理整个苏格拉底式对话的生命周期：
/// - 生成与话题匹配的欢迎消息（AI 主动开口）
/// - 接收用户输入并生成 AI 追问
/// - 跟踪对话轮次
///
/// ## 依赖倒置
/// 通过 [DialogueEngine] 接口解耦：
/// - 注入 [SocraticPrompter] → 端侧 LLM 推理
/// - 注入 Mock 引擎 → 单元测试
/// - 未注入时 → 内置 Mock 回复兜底
///
/// ## ChangeNotifier 模式
/// 继承 ChangeNotifier 后，调用 notifyListeners() 会通知
/// 所有监听者（Widget）刷新 UI。
class ChatProvider extends ChangeNotifier {
  /// 对话话题标题
  final String topic;

  /// 对话引擎（可选注入，未注入时使用内置 Mock）
  final DialogueEngine? _engine;

  /// 当前对话轮次
  ///
  /// 欢迎消息为轮次 0（序言），首轮用户消息从 1 开始。
  int _round = 1;

  /// 是否正在等待 AI 回复
  bool _isThinking = false;

  /// 对话消息列表（内部存储）
  final List<ChatMessage> _messages = [];

  /// 构造函数
  ///
  /// [engine] 可选注入对话引擎（生产环境传入 [SocraticPrompter]）。
  /// 未注入时，sendMessage 自动回退到内置 Mock 回复。
  // ignore: prefer_initializing_formals — _engine is private, can't use this._engine
  ChatProvider({required this.topic, DialogueEngine? engine}) : _engine = engine {
    _addWelcomeMessage();
  }

  // ==============================================================
  // Getters（外部只读访问）
  // ==============================================================

  /// 获取所有消息的不可变列表
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
  /// 2. 标记"思考中"，通知 UI 显示加载动画
  /// 3. 调用 [DialogueEngine] 流式获取 AI 追问（未注入则 Mock）
  /// 4. 每个 token 追加到 AI 占位消息的 content 中
  /// 5. 流结束 → 轮次 +1，标记"思考结束"
  Future<void> sendMessage(String content) async {
    // 步骤 1：添加用户消息
    _messages.add(ChatMessage(
      role: MessageRole.user,
      content: content,
      round: _round,
    ));

    // 步骤 2：标记 AI 开始思考
    _isThinking = true;
    notifyListeners();

    // 步骤 3：添加一个空的 AI 消息占位（后续用 token 填充）
    final aiMessageIndex = _messages.length;
    _messages.add(ChatMessage(
      role: MessageRole.ai,
      content: '',
      round: _round,
    ));

    try {
      final engine = _engine;

      if (engine == null || !engine.isReady) {
        // 引擎未注入或未就绪 → Mock 回退
        _messages[aiMessageIndex] = ChatMessage(
          role: MessageRole.ai,
          content: _generateMockResponse(),
          round: _round,
        );
      } else {
        // ── 首轮对话：注入对话开场白上下文 ──
        if (_round == 1) {
          engine.seedContext(_messages.first.content);
        }

        // 流式获取 AI 回复
        final buffer = StringBuffer();
        await for (final token in engine.generateResponse(content)) {
          buffer.write(token);
          _messages[aiMessageIndex] = ChatMessage(
            role: MessageRole.ai,
            content: buffer.toString(),
            round: _round,
          );
          notifyListeners();
        }
      }
    } catch (e, stack) {
      debugPrint('[ChatProvider] 推理失败: $e');
      debugPrintStack(stackTrace: stack);
      _messages[aiMessageIndex] = ChatMessage(
        role: MessageRole.ai,
        content: '抱歉，我在思考时遇到了一些问题。你能换个方式再说说吗？',
        round: _round,
      );
    } finally {
      _round++;
      _isThinking = false;
      notifyListeners();
    }
  }

  // ==============================================================
  // 私有方法
  // ==============================================================

  /// 生成与话题匹配的欢迎消息（轮次 0 — 序言）
  void _addWelcomeMessage() {
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

    final opening = openings[topic] ?? '你想和我聊聊什么话题？让我们从头开始。';

    _messages.add(ChatMessage(
      role: MessageRole.ai,
      content: opening,
      round: 0,
    ));
  }

  /// 生成 Mock AI 回复（引擎未就绪时的回退方案）
  String _generateMockResponse() {
    const responses = [
      '你提到的这点很有意思——你能给我一个具体的例子吗？',
      '如果完全没有失败的风险，你的答案会变吗？',
      '你刚才说到的这个想法，背后最让你担心的是什么？',
      '换句话说，你觉得这件事对你来说最重要的是什么？',
      '如果一位朋友处在你的位置，你给他什么建议？',
    ];

    return responses[_messages.length % responses.length];
  }
}
