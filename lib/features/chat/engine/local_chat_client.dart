import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;
import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/data/models/dashboard_models.dart';
import 'package:zhixing_ai/core/llm/think_tag_stripper.dart';
import 'package:zhixing_ai/core/logger.dart';
import 'package:zhixing_ai/features/chat/engine/chat_client.dart';
import 'package:zhixing_ai/features/chat/engine/context_policy.dart';
import 'package:zhixing_ai/features/chat/engine/conversation_strategy.dart';
import 'package:zhixing_ai/features/chat/engine/local_context_policy.dart';

/// 端侧推理会话窄接口：KV 缓存句柄，单测以 fake 注入、无需真实模型。
///
/// **它不是「对话会话」**——不保存消息，只持有 llama context 里的 KV 缓存，
/// 使新增消息可做增量 prefill。删掉它行为不变，只是每轮全量重算（见
/// [LocalChatClient] 类注释）。
abstract class KvSession {
  void addSystem(String content);

  void addUser(String content);

  void addAssistant(String content);

  Stream<String> generate({int maxTokens});

  void dispose();
}

/// [EngineChat] → [KvSession] 适配器：事件流收敛为纯 token 文本流。
class LlamaKvSession implements KvSession {
  final EngineChat _inner;

  LlamaKvSession(this._inner);

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
typedef KvSessionFactory = Future<KvSession> Function();

/// 本地（端侧 llama）对话客户端。
///
/// 只负责两件事：
///   1. 把 [ContextPolicy] 的装配结果同步到 KV 会话——**窗口未收缩**时只
///      append 新增消息（增量 prefill，复用已有 KV）；**窗口收缩**使保留
///      消息不再是上一轮的前缀时整体重建（旧 KV 作废，全量 re-prefill）；
///   2. 推理流（think 剥离）与传输层错误（context full）自愈。
///
/// 上下文装配（过滤 / 装窗 / 压缩）不再属于本类，见 [ContextPolicy]。
class LocalChatClient implements ChatClient {
  final ConversationStrategy _strategy;
  final KvSessionFactory _createKv;
  final ContextPolicy _policy;

  /// 当前 KV 会话（推理缓存；不保存消息，与「对话」无关）。
  KvSession? _kv;
  String _systemPrompt = '';

  /// diff 游标：最近一次装配结果中已同步进 KV 会话的条数。
  int _consumed = 0;

  /// 上一轮结束后，历史中紧接着的那条 AI 消息已"结算"：
  /// 正常完成 → 回复已登记，跳过以防重复登记；取消/失败 → 有意缺席，同样跳过。
  /// 两种情形处理一致（只推进游标），在 generateResponse 的 finally 中无条件置位。
  bool _skipNextHistoryAi = false;

  /// [engine] 与 [kvSessionFactory] 必须给其一（构造期 [ArgumentError]）。
  /// 只注入 [kvSessionFactory]（无 [engine]）时摘要引擎不可用：压缩回落纯丢弃。
  /// [policy] 可整体替换（测试注入小预算策略强制触发压缩）。
  LocalChatClient({
    LlamaEngine? engine,
    ConversationStrategy? strategy,
    KvSessionFactory? kvSessionFactory,
    ContextPolicy? policy,
    ConversationSummarizer? summarizer,
  })  : _strategy = strategy ?? ConversationStrategy(),
        _createKv =
            kvSessionFactory ?? (() => engine!.createChat().then(LlamaKvSession.new)),
        _policy = policy ??
            LocalContextPolicy(
              summarizer:
                  summarizer ?? (engine == null ? null : LlamaSummarizer(engine)),
            ) {
    if (engine == null && kvSessionFactory == null) {
      throw ArgumentError('LocalChatClient 需要 engine 或 kvSessionFactory 之一');
    }
  }

  @override
  bool get isReady => _kv != null;

  @override
  Future<bool> initialize({List<Goal> existingGoals = const []}) async {
    try {
      _systemPrompt = _strategy.buildSystemPrompt(existingGoals: existingGoals);
      _kv?.dispose();
      _kv = await _createKv();
      _kv!.addSystem(_systemPrompt);
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
    var kv = _kv;
    if (kv == null) {
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
      // 窗口收缩（含 context full 自愈）：保留消息不再是上一轮的前缀，
      // 已有 KV 无法复用 → 整体重建
      kv = await _rebuildKv(desired, assembled.summaryCard);
      _consumed = desired.length;
    } else {
      var aiSkipped = false;
      for (var i = _consumed; i < desired.length; i++) {
        final msg = desired[i];
        final content = msg.content;

        if (msg.role == MessageRole.ai && skipFirstAi && !aiSkipped) {
          // 见 [_skipNextHistoryAi]：只推进游标，不动 KV 会话。
          aiSkipped = true;
          _consumed++;
          continue;
        }

        if (content.isNotEmpty) {
          if (msg.role == MessageRole.user) {
            final rewritten =
                i == desired.length - 1 && _strategy.isDuplicate(content);
            kv.addUser(rewritten
                ? '$content（请从不同的角度回答，不要重复之前的观点）'
                : content);
          } else {
            kv.addAssistant(content);
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
      await for (final token in kv.generate(maxTokens: AppConstants.localMaxTokens)) {
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
          // 否则 KV 会话登记的回复丢失闭合标签后的主体。
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
        kv.addAssistant(fullReply);
      }
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
          await _rebuildKv(healed.messages, healed.summaryCard);
          _consumed = healed.messages.length;
        } catch (re) {
          AppLogger.error('LocalChatClient', '自愈重建失败', re);
        }
      }
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
    _kv?.dispose();
    _kv = null;
  }

  /// 整体重建 KV 会话：人设 → 摘要卡（如有）→ 保留的对话消息。
  ///
  /// 仅在保留窗口不再是上一轮前缀时调用（窗口收缩 / 溢出自愈）——
  /// 此时旧 KV 全部作废，只能重新 prefill；代价换来窗口回到预算内。
  Future<KvSession> _rebuildKv(
      List<ChatMessage> messages, String? summaryCard) async {
    _kv?.dispose();
    final kv = await _createKv();
    kv.addSystem(_systemPrompt);
    if (summaryCard != null) {
      kv.addSystem(summaryCard);
    }
    for (final msg in messages) {
      if (msg.content.isEmpty) continue;
      if (msg.role == MessageRole.user) {
        kv.addUser(msg.content);
      } else {
        kv.addAssistant(msg.content);
      }
    }
    _kv = kv;
    return kv;
  }

  /// llama 上下文撑爆的特征异常（插件 Generator 在 decode 前置检查抛出）。
  bool _isContextFullError(Object e) =>
      e is LlamaDecodeException || e.toString().contains('context full');
}
