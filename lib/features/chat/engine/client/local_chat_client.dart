import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;
import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/data/models/dashboard_models.dart';
import 'package:zhixing_ai/core/llm/think_tag_stripper.dart';
import 'package:zhixing_ai/core/logger.dart';
import 'package:zhixing_ai/features/chat/engine/client/chat_client.dart';
import 'package:zhixing_ai/features/chat/engine/context/context_policy.dart';
import 'package:zhixing_ai/features/chat/engine/prompt/conversation_strategy.dart';
import 'package:zhixing_ai/features/chat/engine/context/local_context_policy.dart';

/// 端侧推理会话窄接口：一份多轮消息列表 + 每轮全量渲染生成。
///
/// 生产实现是 [EngineChat] 的薄适配（见 [LlamaChatSession]）；单测以 fake
/// 注入，无需真实模型。它持有消息列表、提供 addSystem/addUser/addAssistant
/// 往里塞，[generate] 时由底层把**整份列表**渲染成一条 prompt 交给 worker。
///
/// **它不是 KV 缓存句柄**：底层每轮 generate 都会清空 KV 并全量 re-prefill
/// （包作者注释称跨轮复用是 future optimization），本对象对此无能为力。名字
/// 里的 Session 指「一次对话会话」的运行时状态，与 KV 缓存无关。
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
  Stream<String> generate({int maxTokens = AppConstants.localMaxTokens}) async* {
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
typedef ChatSessionFactory = Future<ChatSession> Function();

/// 本地（端侧 llama）对话客户端。
///
/// 只负责两件事：
///   1. 把 [ContextPolicy] 的装配结果同步到 [ChatSession]——窗口未收缩时
///      增量补差（只 add 新增条目）；窗口收缩时整体重建会话对象（全量重塞）；
///   2. 推理流（think 剥离）与传输层错误（context full）自愈。
///
/// **「增量」的真实收益**：底层 [EngineChat] 每轮 generate 都会 `session.clear()`
/// 后从头 re-prefill 整条 prompt，跨轮 KV 复用**并不存在**。因此「增量补差 vs
/// 整体重建」的唯一实际差别是**是否重建 [EngineChat]**（`LlamaEngine.createChat()`
/// 会连带新建其内部 EngineSession，故省下的是一次 worker RPC + 重塞消息），
/// 与 prefill 算力无关。
///
/// 上下文装配（过滤 / 装窗 / 压缩）不再属于本类，见 [ContextPolicy]。
class LocalChatClient implements ChatClient {
  final ConversationStrategy _strategy;
  final ChatSessionFactory _createSession;
  final ContextPolicy _policy;

  /// 当前推理会话（持消息列表；与 KV 缓存无关，见 [ChatSession]）。
  ChatSession? _session;
  String _systemPrompt = '';

  /// diff 游标：最近一次装配结果中已同步进会话的条数。
  int _consumed = 0;

  /// 上一轮结束后，历史中紧接着的那条 AI 消息已在会话内「落地」：
  /// 底层 [EngineChat] 每次 generate 收尾都会把回复自动追加进其消息列表
  /// （正常完成=全文，取消/失败=已生成部分），故历史里的本条**无需再 add**。
  /// 置位后在下一轮跳过它，避免同一回复被登记两遍。
  /// 在 generateResponse 的 finally 中无条件置位。
  bool _skipNextHistoryAi = false;

  /// [engine] 与 [sessionFactory] 必须给其一（构造期 [ArgumentError]）。
  /// 只注入 [sessionFactory]（无 [engine]）时摘要引擎不可用：压缩回落纯丢弃。
  /// [policy] 可整体替换（测试注入小预算策略强制触发压缩）。
  LocalChatClient({
    LlamaEngine? engine,
    ConversationStrategy? strategy,
    ChatSessionFactory? sessionFactory,
    ContextPolicy? policy,
    ConversationSummarizer? summarizer,
  })  : _strategy = strategy ?? ConversationStrategy(),
        _createSession = sessionFactory ??
            (() => engine!.createChat().then(LlamaChatSession.new)),
        _policy = policy ??
            LocalContextPolicy(
              summarizer:
                  summarizer ?? (engine == null ? null : LlamaSummarizer(engine)),
            ) {
    if (engine == null && sessionFactory == null) {
      throw ArgumentError('LocalChatClient 需要 engine 或 sessionFactory 之一');
    }
  }

  @override
  bool get isReady => _session != null;

  @override
  Future<bool> initialize({List<Goal> existingGoals = const []}) async {
    try {
      _systemPrompt = _strategy.buildSystemPrompt(existingGoals: existingGoals);
      _session?.dispose();
      _session = await _createSession();
      _session!.addSystem(_systemPrompt);
      _policy.reset();
      _consumed = 0;
      _skipNextHistoryAi = false;
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

    // 装配（过滤 + 装窗 + 压缩）委托策略
    final assembled =
        await _policy.assemble(history, systemPrompt: _systemPrompt);
    final desired = assembled.messages;

    if (assembled.evicted) {
      // 窗口收缩（含 context full 自愈）：保留消息不再是上一轮的前缀 →
      // 重建会话对象，全量重塞
      session = await _rebuildSession(desired, assembled.summaryCard);
      _consumed = desired.length;
    } else {
      var aiSkipped = false;
      for (var i = _consumed; i < desired.length; i++) {
        final msg = desired[i];
        final content = msg.content;

        if (msg.role == MessageRole.ai && skipFirstAi && !aiSkipped) {
          // 见 [_skipNextHistoryAi]：底层已自动登记该回复，只推进游标、不再 add。
          aiSkipped = true;
          _consumed++;
          continue;
        }

        if (content.isNotEmpty) {
          if (msg.role == MessageRole.user) {
            final rewritten =
                i == desired.length - 1 && _strategy.isDuplicate(content);
            session.addUser(rewritten
                ? '$content（请从不同的角度回答，不要重复之前的观点）'
                : content);
          } else {
            session.addAssistant(content);
          }
        }
        _consumed++;
      }
    }

    // think 剥离流式输出
    final buffer = StringBuffer();
    var passedThink = false;
    var suppressWhitespace = false;
    try {
      await for (final token in session.generate(maxTokens: AppConstants.localMaxTokens)) {
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
          // token 必须同步写 buffer：结束时提取收尾正文依赖其完整性。
          buffer.write(token);
          yield token;
        }
      }

      final fullReply = stripThinkTags(buffer.toString());
      if (!passedThink && fullReply.isNotEmpty) {
        // 兜底：非思考模式（无闭合标签）时缓冲内容即正文，不 yield 会空气泡。
        yield fullReply;
      }
      // 回复的「登记」由底层 [EngineChat] 自动完成（每轮收尾追加），此处
      // 不得再 addAssistant——否则同一回复会在下一轮 prompt 中出现两遍。
    } catch (e) {
      AppLogger.error('LocalChatClient', '生成回复失败', e);
      // context full = 真实上下文先于估算撑爆（估算漂移）。插件每次 generate
      // 都全量重渲染 prompt，重建不减内容则依旧撑爆——必须真正减少保留条数。
      if (_isContextFullError(e)) {
        try {
          // 自愈：策略强制收缩，随即重新装配并重建会话（下一轮直接可用）
          await _policy.handleOverflow();
          final healed =
              await _policy.assemble(history, systemPrompt: _systemPrompt);
          await _rebuildSession(healed.messages, healed.summaryCard);
          _consumed = healed.messages.length;
        } catch (re) {
          AppLogger.error('LocalChatClient', '自愈重建失败', re);
        }
      }
      yield '\n\n[助手暂时无法回应，请稍后再试]';
    } finally {
      // 无论正常完成（底层已登记回复）还是取消/失败（部分回复亦由底层登记），
      // 历史中对应的那条 AI 都应跳过，避免下一轮重复 add。
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

  /// 整体重建会话：人设 → 摘要卡（如有）→ 保留的对话消息。
  ///
  /// 仅在保留窗口不再是上一轮前缀时调用（窗口收缩 / 溢出自愈）——旧会话的
  /// 消息列表与保留窗口不一致，只能废弃重建；代价是新建一个 [EngineChat]
  /// （连带其内部 EngineSession）并全量重塞消息（prefill 本就每轮全量，与此无关）。
  Future<ChatSession> _rebuildSession(
      List<ChatMessage> messages, String? summaryCard) async {
    _session?.dispose();
    final session = await _createSession();
    session.addSystem(_systemPrompt);
    if (summaryCard != null) {
      session.addSystem(summaryCard);
    }
    for (final msg in messages) {
      if (msg.content.isEmpty) continue;
      if (msg.role == MessageRole.user) {
        session.addUser(msg.content);
      } else {
        session.addAssistant(msg.content);
      }
    }
    _session = session;
    return session;
  }

  /// llama 上下文撑爆的特征异常（插件 Generator 在 decode 前置检查抛出）。
  bool _isContextFullError(Object e) =>
      e is LlamaDecodeException || e.toString().contains('context full');
}
