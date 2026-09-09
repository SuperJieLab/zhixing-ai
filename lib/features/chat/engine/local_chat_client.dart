import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;
import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/engine/llama_service.dart';
import 'package:zhixing_ai/core/logger.dart';
import 'package:zhixing_ai/core/models/chat_models.dart';
import 'package:zhixing_ai/core/models/dashboard_models.dart';
import 'package:zhixing_ai/core/think_tag_stripper.dart';
import 'package:zhixing_ai/features/chat/engine/chat_client.dart';
import 'package:zhixing_ai/features/chat/engine/conversation_strategy.dart';

/// llama 会话的最小抽象（窄接口）
///
/// [LocalChatClient] 只依赖这五个操作，单测用 fake 注入即可覆盖增量 diff、
/// 截断重建、去重改写等逻辑，无需真实模型。默认实现 [LlamaChatSession]
/// 包装 llama_cpp_dart 的 [EngineChat]。
abstract class ChatSession {
  void addSystem(String content);

  void addUser(String content);

  void addAssistant(String content);

  /// 流式生成回复 token 文本。
  Stream<String> generate({int maxTokens});

  void dispose();
}

/// [EngineChat] → [ChatSession] 适配器
///
/// 把 llama 的事件流收敛为纯 token 文本流（只透传 [TokenEvent]），
/// 采样参数在此固定（与原 StrategistPrompter 一致）。
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

/// 会话工厂：生产环境包 [LlamaEngine.createChat]，测试注入 fake。
typedef SessionFactory = Future<ChatSession> Function();

/// 本地（端侧 llama）对话客户端，实现 [ChatClient]
///
/// 从 StrategistPrompter 拆出的传输层职责：
///   - 收完整历史自行 diff（[_consumed]），只把新增消息 append 进 session
///     （增量 prefill，不整段重放；恢复会话时首调自然完成全量 seed，
///     欢迎语也入 session，与旧 seedHistory 等价）
///   - 尾部用户消息过 [ConversationStrategy.isDuplicate] 决定 session 侧改写
///     （mirror 只存原文，与旧行为一致）
///   - 超上下文估算阈值自动截断：session 重建，mirror 保留最近 12 条
///   - think 标签剥离流式输出（逐行搬自原实现）
///   - 取消/失败轮的 assistant 不登记 session 与 mirror（与旧实现一致）；
///     生成结束后（无论成败）下一轮 diff 都跳过历史中紧接着的那条 AI 消息
///     ——正常完成时它已由生成流程登记，跳过以防重复（[_skipNextHistoryAi]）
///
/// 消费方：ChatProvider（唯一），不跨 feature 共享。
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

  /// 上一轮生成结束后，历史中紧接着的那条 AI 消息已"结算"：
  ///   - 正常完成 → 回复已由生成流程登记进 session/mirror（addAssistant），
  ///     下一轮 diff 再遇到它会重复登记 → 需跳过；
  ///   - 取消/失败 → assistant 有意不登记，下一轮 diff 同样跳过该条。
  /// 两种情形对 diff 的处理一致（只推进 [_consumed]，不动 session/mirror），
  /// 故共用一个标志，在 generateResponse 的 finally 中无条件置位。
  bool _skipNextHistoryAi = false;

  static const _maxTokens = 2048;

  /// [engine] 与 [sessionFactory] 至少给一个：都缺省时生成阶段抛
  /// [StateError]（测试只注入 fake factory，不触碰真实引擎）。
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

    // ---- diff：只 append 新增部分（恢复会话时 _consumed==0，全量 seed）----
    for (var i = _consumed; i < history.length; i++) {
      final msg = history[i];
      final content = msg.content;

      if (msg.role == MessageRole.ai && skipFirstAi && !aiSkipped) {
        // 上一轮生成的回复：正常完成时已登记（重复 append 会让 session 出现
        // 重复 assistant 轮），取消/失败时有意缺席——两种情形都只推进游标。
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

    // ---- 生成（think 剥离逻辑与原 StrategistPrompter 逐行一致）----
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
          // else: still in think section, suppress output
        } else if (suppressWhitespace) {
          // Still absorbing whitespace after </think>
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
          // 注意：token 需同步写入 buffer——结束时 addAssistant 登记的
          // fullReply 依赖 buffer 的完整性（原 StrategistPrompter 此分支
          // 不写 buffer，导致 session 登记的回复丢失闭合标签后的主体）。
          buffer.write(token);
          yield token;
        }
      }

      final fullReply = stripThinkTags(buffer.toString());
      if (!passedThink && fullReply.isNotEmpty) {
        // 兜底：模型未输出 think 闭合标签（非思考模式）时，缓冲内容即正文。
        // 原 StrategistPrompter 此场景整段静默丢弃（流为空 → UI 空气泡）。
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
      // 无论正常完成（回复已登记，防重复）还是取消/失败（有意缺席），
      // 下一轮 diff 都要跳过历史中紧接着的那条 AI 消息。
      // （流被取消时 async* 生成器的 finally 保证执行。）
      _skipNextHistoryAi = true;
    }
  }

  @override
  void stop() {
    // 本地流的中断由 Provider 取消订阅完成（async* 生成器随之终止并跳过
    // assistant 登记），此处无需额外动作。
  }

  @override
  void dispose() {
    _session?.dispose();
    _session = null;
  }

  // ================================================================
  // 上下文截断
  // ================================================================

  Future<void> _truncateContext() async {
    // Keep only the last 6 exchanges (12 messages: user-assistant pairs)
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
