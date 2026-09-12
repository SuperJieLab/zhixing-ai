import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;
import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/data/models/dashboard_models.dart';
import 'package:zhixing_ai/core/llm/context_assembly.dart';
import 'package:zhixing_ai/core/llm/inference.dart';
import 'package:zhixing_ai/core/llm/local_context_policy.dart';
import 'package:zhixing_ai/core/llm/think_tag_stripper.dart';
import 'package:zhixing_ai/core/logger.dart';
import 'package:zhixing_ai/features/chat/engine/client/chat_client.dart';
import 'package:zhixing_ai/features/chat/engine/prompt/conversation_strategy.dart';

/// 端侧推理会话窄接口：一份多轮消息列表 + 每轮全量渲染生成。
///
/// 它是 [LocalChatClient] 唯一的 SDK 依赖点，也是**测试接缝**——单测注入 fake
/// 即可覆盖压缩、自愈、think 剥离等路径，无需加载真实模型。生产实现见
/// [LlamaChatSession]（`EngineChat` 的薄适配）。
///
/// 名字里的 Session 指「一次对话会话」，**与 KV 缓存无关**：底层每轮 generate
/// 都清空 KV 并全量 re-prefill，跨轮复用不存在。勿再改回 `Kv*` 命名。
abstract class ChatSession {
  /// 清空会话侧消息列表（转发 `EngineChat.clearHistory()`，零 RPC）。
  /// 无状态重放的起点。
  void clear();

  void addSystem(String content);

  void addUser(String content);

  void addAssistant(String content);

  Stream<String> generate({int maxTokens});

  void dispose();
}

/// [EngineChat] → [ChatSession] 适配器：事件流收敛为纯 token 文本流
/// （收敛原语见 `core/llm/inference.dart` 的 `eventsToText`）。
class LlamaChatSession implements ChatSession {
  final EngineChat _inner;

  LlamaChatSession(this._inner);

  @override
  void clear() => _inner.clearHistory();

  @override
  void addSystem(String content) => _inner.addSystem(content);

  @override
  void addUser(String content) => _inner.addUser(content);

  @override
  void addAssistant(String content) => _inner.addAssistant(content);

  @override
  Stream<String> generate({int maxTokens = AppConstants.localMaxTokens}) =>
      eventsToText(_inner.generate(
        sampler: const SamplerParams(
          temperature: 0.7,
          topP: 0.9,
          repeatPenalty: 1.1,
        ),
        maxTokens: maxTokens,
      ));

  @override
  void dispose() => _inner.dispose();
}

/// 生产包 [LlamaEngine.createChat]，测试注入 fake。
typedef ChatSessionFactory = Future<ChatSession> Function();

/// 本地（端侧 llama）对话客户端。
///
/// 职责：① 把 [ContextPolicy] 的装配结果「清空 + 全量重放」到 [ChatSession]
/// （见 [_syncSession]）；② think 剥离；③ `context full` 自愈。
///
/// **为何每轮重放而非增量补差**：`EngineChat` 收尾会把回复（含 think 原文）自动
/// 登记进自己的列表，增量喂法会有两份必然漂移的列表，只能靠游标 + 位置型补丁
/// 对齐。重放后引擎不再持有权威副本——唯一真相源是 `ChatProvider._messages`，
/// 与云端（每轮现拼现发）同构。成本仅 N 次本地 `List.add`（零 RPC）。
/// 设计见 `docs/plans/2026-09-11-local-stateless-replay-design.md`。
///
/// 上下文装配（过滤 / 装窗 / 压缩）不属于本类，见 [ContextPolicy]。
class LocalChatClient implements ChatClient {
  final ConversationStrategy _strategy;
  final ChatSessionFactory _createSession;
  final ContextPolicy _policy;

  /// 当前推理会话。全生命周期只有**一个**（[initialize] 创建），此后只 clear + 重放。
  ChatSession? _session;
  String _systemPrompt = '';

  /// 会话压缩状态（Task 3 后由业务持有并传入；本步先由交付实现暂持）。
  final ContextState _state = ContextState();

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
      _state.reset();
      return true;
    } catch (e) {
      AppLogger.error('LocalChatClient', '初始化失败', e);
      return false;
    }
  }

  @override
  Stream<String> generateResponse(List<ChatMessage> history) async* {
    final session = _session;
    if (session == null) {
      AppLogger.warn('LocalChatClient', '引擎未初始化');
      yield '助手尚在准备中，请稍后再来。';
      return;
    }

    // 装配（过滤 + 装窗 + 压缩）委托策略，随后无状态重放到会话
    final assembled = await _policy.assemble(
      history,
      state: _state,
      systemPrompt: _systemPrompt,
    );
    _syncSession(session, assembled);

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
    } catch (e) {
      AppLogger.error('LocalChatClient', '生成回复失败', e);
      // context full = 真实上下文先于估算撑爆，必须真正减少保留条数才能自愈。
      if (_isContextFullError(e)) {
        try {
          // 自愈：策略强制收缩后重新装配重放（下一轮直接可用）。
          // nudgeTail: false —— 本轮已判定过尾问，不得重复计入去重窗口。
          _policy.handleOverflow(_state);
          final healed = await _policy.assemble(
            history,
            state: _state,
            systemPrompt: _systemPrompt,
          );
          _syncSession(session, healed, nudgeTail: false);
        } catch (re) {
          AppLogger.error('LocalChatClient', '自愈重放失败', re);
        }
      }
      yield '\n\n[助手暂时无法回应，请稍后再试]';
    }
  }

  @override
  void stop() {
    // 本地流中断由 Provider 取消订阅完成，无遗留状态需清理：下一轮会 clear 重放。
  }

  @override
  void dispose() {
    _session?.dispose();
    _session = null;
  }

  /// 无状态重放：清空消息列表，再按「人设 → 摘要卡 → 装配结果」全量重建，
  /// 使引擎内列表恒等于本轮装配结果。本类与 SDK 之间唯一的会话同步点。
  ///
  /// [nudgeTail] 为尾部用户消息的去重改写开关（上一问高度相似 → 提示换角度）。
  /// `isDuplicate` 有状态（会把问题记入滚动窗口），故同一次 [generateResponse]
  /// 内只允许调用一次：溢出自愈的二次重放须传 `false`。
  void _syncSession(
    ChatSession session,
    AssembledContext assembled, {
    bool nudgeTail = true,
  }) {
    session.clear();
    session.addSystem(_systemPrompt);
    final summaryCard = assembled.summaryCard;
    if (summaryCard != null) {
      session.addSystem(summaryCard);
    }
    final messages = assembled.messages;
    final last = messages.length - 1;
    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];
      if (msg.content.isEmpty) continue;
      if (msg.role == MessageRole.user) {
        final rewritten = nudgeTail && i == last && _strategy.isDuplicate(msg.content);
        session.addUser(rewritten
            ? '${msg.content}（请从不同的角度回答，不要重复之前的观点）'
            : msg.content);
      } else {
        session.addAssistant(msg.content);
      }
    }
  }

  /// llama 上下文撑爆的特征异常（插件 Generator 在 decode 前置检查抛出）。
  bool _isContextFullError(Object e) =>
      e is LlamaDecodeException || e.toString().contains('context full');
}
