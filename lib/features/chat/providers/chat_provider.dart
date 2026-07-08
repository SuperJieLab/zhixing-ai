import 'package:flutter/foundation.dart';

import '../../../core/engine/dialogue_engine.dart';
import '../../../core/engine/llama_service.dart';
import '../../../core/models/chat_models.dart';
import '../../insights/engine/insight_service.dart';
import '../engine/socratic_prompter.dart';

/// 对话状态管理
///
/// 负责整个苏格拉底式对话的完整生命周期：
/// - 加载 LLM 模型（loadModel）
/// - 生成欢迎消息 + 接收用户输入 + 生成 AI 追问（sendMessage）
/// - 结束对话并生成洞察总结（endConversation）
///
/// ## 分层
/// ChatPage 只通过 ChatProvider 交互，不直接接触 LlamaService / SocraticPrompter / InsightService。
///
/// ## ChangeNotifier 模式
/// 调用 notifyListeners() 通知所有监听者（Widget）刷新 UI。
class ChatProvider extends ChangeNotifier {
  /// 对话话题标题
  final String topic;

  /// 消息变更回调（由 ChatPage 注入持久化写入逻辑）
  final VoidCallback? _onMessagesChanged;

  // ================================================================
  // 引擎状态
  // ================================================================

  DialogueEngine? _engine;
  bool _isModelLoading = false;
  String? _modelError;

  /// 模型是否已就绪
  bool get isModelReady => _engine != null && _engine!.isReady;

  /// 模型是否加载中
  bool get isModelLoading => _isModelLoading;

  /// 模型加载错误信息
  String? get modelError => _modelError;

  // ================================================================
  // 对话状态
  // ================================================================

  int _round = 1;
  bool _isThinking = false;
  final List<ChatMessage> _messages = [];

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  int get round => _round;
  bool get isThinking => _isThinking;

  // ================================================================
  // 生命周期
  // ================================================================

  ChatProvider({
    required this.topic,
    VoidCallback? onMessagesChanged,
  }) : _onMessagesChanged = onMessagesChanged {
    _addWelcomeMessage();
  }

  @override
  void dispose() {
    if (_engine is SocraticPrompter) {
      (_engine as SocraticPrompter).dispose();
    }
    super.dispose();
  }

  // ================================================================
  // 引擎初始化
  // ================================================================

  /// 加载 LLM 模型（异步，通知 UI 加载状态）
  ///
  /// 加载成功后 _engine 就绪，sendMessage 使用 LLM 推理。
  /// 加载失败后 _engine 保持 null，sendMessage 回退 Mock。
  Future<void> loadModel() async {
    _isModelLoading = true;
    notifyListeners();

    try {
      final llmEngine = await LlamaService.instance.ensureReady();
      final engine = SocraticPrompter(llmEngine);
      await engine.initialize();
      _engine = engine;
    } catch (e) {
      debugPrint('[ChatProvider] 模型加载失败，将使用 Mock 回复: $e');
      _modelError = e.toString();
    } finally {
      _isModelLoading = false;
      notifyListeners();
    }
  }

  // ================================================================
  // 对话
  // ================================================================

  /// 用户发送一条消息
  Future<void> sendMessage(String content) async {
    _messages.add(ChatMessage(
      role: MessageRole.user,
      content: content,
      round: _round,
    ));

    _isThinking = true;
    notifyListeners();

    final aiMessageIndex = _messages.length;
    _messages.add(ChatMessage(
      role: MessageRole.ai,
      content: '',
      round: _round,
    ));

    try {
      final engine = _engine;

      if (engine == null || !engine.isReady) {
        _messages[aiMessageIndex] = ChatMessage(
          role: MessageRole.ai,
          content: _generateMockResponse(),
          round: _round,
        );
      } else {
        if (_round == 1) {
          engine.seedContext(_messages.first.content);
        }

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
      _onMessagesChanged?.call();
    }
  }

  /// 结束对话，生成洞察总结
  ///
  /// 通过 InsightService 调用 LLM 分析完整对话历史。
  /// 引擎未就绪时返回空结果。
  Future<InsightResult> endConversation() async {
    final engine = _engine;
    if (engine == null || engine is! SocraticPrompter) {
      return const InsightResult(
        coreInsights: [],
        underlyingValues: [],
        contradictionsFound: [],
      );
    }

    try {
      final service = InsightService(engine.engine);
      return await service.analyze(topic, messages);
    } catch (e) {
      debugPrint('[ChatProvider] 洞察生成失败: $e');
      return const InsightResult(
        coreInsights: ['对话分析完成'],
        underlyingValues: [],
        contradictionsFound: [],
      );
    }
  }

  // ================================================================
  // 私有
  // ================================================================

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
