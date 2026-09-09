import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;
import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/engine/llama_service.dart';
import 'package:zhixing_ai/core/logger.dart';
import 'package:zhixing_ai/core/models/chat_models.dart';
import 'package:zhixing_ai/core/models/dashboard_models.dart';
import 'package:zhixing_ai/core/think_tag_stripper.dart';
import 'package:zhixing_ai/features/chat/engine/chat_client.dart';
import 'package:zhixing_ai/features/chat/engine/conversation_strategy.dart';

/// llama 会话窄接口：单测以 fake 注入，无需真实模型。
abstract class ChatSession {
  void addSystem(String content);

  void addUser(String content);

  void addAssistant(String content);

  Stream<String> generate({int maxTokens});

  void dispose();
}

/// [EngineChat] → [ChatSession] 适配器：事件流收敛为纯 token 文本流。
class LlamaChatSession implements ChatSession {
  final EngineChat _inner;

  LlamaChatSession(this._inner);

  @override
  void addSystem(String content) => _inner.addSystem(content);

  @override
  void addUser(String content) => _inner.addUser(content);

  @override
  void addAssistant(String content) => _inner.addAssistant(content);

  @override
  Stream<String> generate({int maxTokens = 2048}) async* {
    await for (final event in _inner.generate(
      sampler: const SamplerParams(
        temperature: 0.7,
        topP: 0.9,
        repeatPenalty: 1.1,
      ),
      maxTokens: maxTokens,
    )) {
      if (event is TokenEvent) yield event.text;
    }
  }

  @override
  void dispose() => _inner.dispose();
}

/// 生产包 [LlamaEngine.createChat]，测试注入 fake。
typedef SessionFactory = Future<ChatSession> Function();

/// 本地（端侧 llama）对话客户端。
///
/// 收完整历史自行 diff（[_consumed] 计数），只把新增消息 append 进 session
/// （增量 prefill；恢复会话时首调自然完成全量 seed，欢迎语也入 session）。
/// 尾部用户消息过 [ConversationStrategy.isDuplicate] 决定 session 侧改写
/// （mirror 只存原文）；超阈值时重建 session，mirror 保留最近 12 条。
class LocalChatClient implements ChatClient {
  final ConversationStrategy _strategy;
  final SessionFactory _createSession;

  /// 截断阈值（token 估算），默认 75% 上下文窗口；测试可注入小值强制触发。
  final int _truncateThreshold;

  ChatSession? _session;
  String _systemPrompt = '';
  final List<({String role, String content})> _mirror = [];
  int _consumed = 0;
  int _estimatedTokens = 0;

  /// 上一轮结束后，历史中紧接着的那条 AI 消息已"结算"：
  /// 正常完成 → 回复已登记，跳过以防重复登记；取消/失败 → 有意缺席，同样跳过。
  /// 两种情形处理一致（只推进游标），在 generateResponse 的 finally 中无条件置位。
  bool _skipNextHistoryAi = false;

  static const _maxTokens = 2048;

  /// [engine] 与 [sessionFactory] 至少给一个，都缺省时建 session 抛 [StateError]。
  LocalChatClient({
    LlamaEngine? engine,
    ConversationStrategy? strategy,
    SessionFactory? sessionFactory,
    int? truncateThreshold,
  })  : _strategy = strategy ?? ConversationStrategy(),
        _createSession = sessionFactory ??
            (() {
              final e = engine;
              if (e == null) {
                throw StateError(
                    'LocalChatClient 需要 engine 或 sessionFactory 之一');
              }
              return e.createChat().then(LlamaChatSession.new);
            }),
        _truncateThreshold = truncateThreshold ??
            (AppConstants.modelContextSize * 0.75).round();

  @override
  bool get isReady => _session != null;

  @override
  Future<bool> initialize({List<Goal> existingGoals = const []}) async {
    try {
      _systemPrompt = _strategy.buildSystemPrompt(existingGoals: existingGoals);
      _session?.dispose();
      _session = await _createSession();
      _session!.addSystem(_systemPrompt);
      _mirror.clear();
      _consumed = 0;
      _skipNextHistoryAi = false;
      _estimatedTokens = LlamaService.estimateTokens(_systemPrompt);
      return true;
    } catch (e) {
      AppLogger.error('LocalChatClient', '初始化失败', e);
      return false;
    }
  }

  @override
  Stream<String> generateResponse(List<ChatMessage> history) async* {
    var session = _session;
    if (session == null) {
      AppLogger.warn('LocalChatClient', '引擎未初始化');
      yield '助手尚在准备中，请稍后再来。';
      return;
    }

    final skipFirstAi = _skipNextHistoryAi;
    _skipNextHistoryAi = false;
    var aiSkipped = false;

    // diff：只 append 新增部分（恢复会话时 _consumed==0 → 全量 seed）
    for (var i = _consumed; i < history.length; i++) {
      final msg = history[i];
      final content = msg.content;

      if (msg.role == MessageRole.ai && skipFirstAi && !aiSkipped) {
        // 见 [_skipNextHistoryAi]：只推进游标，不动 session/mirror。
        aiSkipped = true;
        _consumed++;
        continue;
      }

      if (content.isNotEmpty) {
        if (msg.role == MessageRole.user) {
          final rewritten = i == history.length - 1 &&
              _strategy.isDuplicate(content);
          session.addUser(rewritten
              ? '$content（请从不同的角度回答，不要重复之前的观点）'
              : content);
        } else {
          session.addAssistant(content);
        }
      }
      _mirror.add((role: msg.role.name, content: content));
      _estimatedTokens += LlamaService.estimateTokens(content);
      _consumed++;
    }

    if (_estimatedTokens > _truncateThreshold) {
      AppLogger.warn(
          'LocalChatClient', '上下文接近上限 (~$_estimatedTokens tokens)，执行截断');
      await _truncateContext();
      session = _session!;
    }

    // think 剥离流式输出
    final buffer = StringBuffer();
    var passedThink = false;
    var suppressWhitespace = false;
    try {
      await for (final token in session.generate(maxTokens: _maxTokens)) {
        if (!passedThink) {
          buffer.write(token);
          final text = buffer.toString();
          final closeIdx1 = text.indexOf('</think>');
          final closeIdx2 = text.indexOf('</思考>');
          final closeIdx = closeIdx1 >= 0
              ? closeIdx1 + '</think>'.length
              : closeIdx2 >= 0
                  ? closeIdx2 + '</思考>'.length
                  : -1;

          if (closeIdx > 0) {
            passedThink = true;
            suppressWhitespace = true;
            final after = text.substring(closeIdx).trimLeft();
            if (after.isNotEmpty) {
              suppressWhitespace = false;
              yield after;
            }
            buffer.clear();
            buffer.write(after);
          }
        } else if (suppressWhitespace) {
          // 吸收 </think> 之后的空白
          buffer.write(token);
          final text = buffer.toString();
          final trimmed = text.trimLeft();
          if (trimmed.isNotEmpty) {
            suppressWhitespace = false;
            buffer.clear();
            buffer.write(trimmed);
            yield trimmed;
          }
        } else {
          // token 必须同步写 buffer：结束时的 addAssistant 依赖其完整性，
          // 否则 session 登记的回复丢失闭合标签后的主体。
          buffer.write(token);
          yield token;
        }
      }

      final fullReply = stripThinkTags(buffer.toString());
      if (!passedThink && fullReply.isNotEmpty) {
        // 兜底：非思考模式（无闭合标签）时缓冲内容即正文，不 yield 会空气泡。
        yield fullReply;
      }
      if (fullReply.isNotEmpty) {
        session.addAssistant(fullReply);
        _estimatedTokens += LlamaService.estimateTokens(fullReply);
        _mirror.add((role: 'assistant', content: fullReply));
      }
    } catch (e) {
      AppLogger.error('LocalChatClient', '生成回复失败', e);
      yield '\n\n[助手暂时无法回应，请稍后再试]';
    } finally {
      // 正常完成（已登记，防重复）与取消/失败（有意缺席）都需跳过下一条 AI 历史。
      // （流被取消时 async* 生成器的 finally 保证执行。）
      _skipNextHistoryAi = true;
    }
  }

  @override
  void stop() {
    // 本地流中断由 Provider 取消订阅完成，finally 里的 skip 标志随之生效。
  }

  @override
  void dispose() {
    _session?.dispose();
    _session = null;
  }

  Future<void> _truncateContext() async {
    // 保留最近 6 组问答（12 条）
    const keepCount = 12;
    if (_mirror.length <= keepCount) return;

    _mirror.removeRange(0, _mirror.length - keepCount);

    _session?.dispose();
    _session = await _createSession();
    _session!.addSystem(_systemPrompt);
    _estimatedTokens = LlamaService.estimateTokens(_systemPrompt);

    for (final msg in _mirror) {
      if (msg.content.isEmpty) continue;
      if (msg.role == 'user') {
        _session!.addUser(msg.content);
      } else {
        _session!.addAssistant(msg.content);
      }
      _estimatedTokens += LlamaService.estimateTokens(msg.content);
    }

    AppLogger.info('LocalChatClient',
        '上下文截断完成: 保留最近 ${_mirror.length} 条消息, ~$_estimatedTokens tokens');
  }
}
