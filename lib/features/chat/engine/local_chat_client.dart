import 'package:flutter/foundation.dart' show visibleForTesting;
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
typedef SessionFactory = Future<ChatSession> Function();

/// 摘要生成器：把旧摘要 + 被移出上下文的消息压成新摘要。
/// 异常由调用方（compact）兜底回落；测试注入 fake。
typedef Summarizer = Future<String> Function(
    String previousSummary, List<({String role, String content})> dropped);

/// 生产摘要实现：一次性独立 session，不污染对话 session 上下文。
/// [think 标签剥离]：摘要模型同为思考模型，取闭合标签后的正文。
Future<String> llamaSummarizer(
  LlamaEngine engine,
  String previousSummary,
  List<({String role, String content})> dropped,
) async {
  final chat = await engine.createChat();
  try {
    chat.addSystem(ConversationStrategy.buildSummaryPrompt(
      previousSummary: previousSummary,
      dropped: dropped,
    ));
    chat.addUser('请输出摘要。');
    final buf = StringBuffer();
    await for (final event in chat.generate(
      sampler: const SamplerParams(temperature: 0.3),
      maxTokens: 512,
    )) {
      if (event is TokenEvent) buf.write(event.text);
    }
    return stripThinkTags(buf.toString());
  } finally {
    chat.dispose();
  }
}

/// 本地（端侧 llama）对话客户端。
///
/// 收完整历史自行 diff（[_consumed] 计数），只把新增消息 append 进 session
/// （增量 prefill；恢复会话时首调自然完成全量 seed，欢迎语也入 session）。
/// 尾部用户消息过 [ConversationStrategy.isDuplicate] 决定 session 侧改写
/// （mirror 只存原文）；超阈值时预算驱动压缩（滚动摘要 + 尾部装窗）。
class LocalChatClient implements ChatClient {
  final ConversationStrategy _strategy;
  final SessionFactory _createSession;

  /// 为 null 表示无可用摘要引擎（sessionFactory-only 注入）：
  /// 压缩时明确回落纯丢弃并 warn，不静默装作有摘要能力。
  final Summarizer? _summarizer;

  /// 截断阈值（token 估算），默认 75% 上下文窗口；测试可注入小值强制触发。
  final int _truncateThreshold;

  ChatSession? _session;
  String _systemPrompt = '';

  /// 递归压实的对话摘要（压缩产物，非对话历史；随 session 重建滚动更新）。
  String _summary = '';
  final List<({String role, String content})> _mirror = [];
  int _consumed = 0;
  int _estimatedTokens = 0;

  /// 上一轮结束后，历史中紧接着的那条 AI 消息已"结算"：
  /// 正常完成 → 回复已登记，跳过以防重复登记；取消/失败 → 有意缺席，同样跳过。
  /// 两种情形处理一致（只推进游标），在 generateResponse 的 finally 中无条件置位。
  bool _skipNextHistoryAi = false;

  /// 每条消息的 template 包装开销（角色标记等），估算时逐条累加。
  static const _perMessageOverhead = 16;

  /// [engine] 与 [sessionFactory] 必须给其一（构造期 [ArgumentError]）。
  /// 只注入 [sessionFactory]（无 [engine]）时摘要引擎不可用：压缩回落纯丢弃。
  LocalChatClient({
    LlamaEngine? engine,
    ConversationStrategy? strategy,
    SessionFactory? sessionFactory,
    int? truncateThreshold,
    Summarizer? summarizer,
  })  : _strategy = strategy ?? ConversationStrategy(),
        _createSession =
            sessionFactory ?? (() => engine!.createChat().then(LlamaChatSession.new)),
        _summarizer = summarizer ??
            (engine == null ? null : ((p, d) => llamaSummarizer(engine, p, d))),
        _truncateThreshold = truncateThreshold ?? AppConstants.localInputBudget {
    if (engine == null && sessionFactory == null) {
      throw ArgumentError('LocalChatClient 需要 engine 或 sessionFactory 之一');
    }
  }

  /// 当前截断阈值（测试观测用：默认值 = nCtx − maxTokens − margin）。
  @visibleForTesting
  int get truncateThreshold => _truncateThreshold;

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
      _summary = '';
      _consumed = 0;
      _skipNextHistoryAi = false;
      _estimatedTokens =
          LlamaService.estimateTokens(_systemPrompt) + _perMessageOverhead;
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
      _estimatedTokens +=
          LlamaService.estimateTokens(content) + _perMessageOverhead;
      _consumed++;
    }

    if (_estimatedTokens > _truncateThreshold) {
      AppLogger.warn(
          'LocalChatClient', '上下文接近上限 (~$_estimatedTokens tokens)，执行压缩');
      await _compactContext();
      session = _session!;
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
        _estimatedTokens +=
            LlamaService.estimateTokens(fullReply) + _perMessageOverhead;
        _mirror.add((role: 'assistant', content: fullReply));
      }
    } catch (e) {
      AppLogger.error('LocalChatClient', '生成回复失败', e);
      // context full = 真实上下文先于估算撑爆（估算漂移）。插件每次 generate
      // 都全量重渲染 prompt，重建不减内容则依旧撑爆——必须真正减少保留条数。
      if (_isContextFullError(e)) {
        try {
          await _compactContext(force: true);
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
    _session?.dispose();
    _session = null;
  }

  /// llama 上下文撑爆的特征异常（插件 Generator 在 decode 前置检查抛出）。
  bool _isContextFullError(Object e) =>
      e is LlamaDecodeException || e.toString().contains('context full');

  /// 预算驱动上下文压缩（替换旧的固定 12 条截断）：
  ///
  /// 常规路径：从尾部往前装窗，能塞进预算（阈值）的最近消息保留原文，
  /// 装不下的 [dropped] 交给 [Summarizer] 与旧摘要合并压成新摘要卡；
  /// 摘要失败回落为纯丢弃。dropped 为空时仅重建 session（不调摘要器）。
  ///
  /// 自愈路径（[force]）：真实上下文已撑爆、估算不可信——硬性只留最后 4 条
  /// 保证内容真正减少（插件每次 generate 全量重渲染 prompt），且不调摘要器。
  Future<void> _compactContext({bool force = false}) async {
    final budget = _truncateThreshold;

    // 1) 计算保留窗口（cut = dropped 与 kept 的分界）
    int cut;
    if (force) {
      cut = _mirror.length > 4 ? _mirror.length - 4 : 0;
    } else {
      cut = _mirror.length;
      var used =
          LlamaService.estimateTokens(_systemPrompt) + _perMessageOverhead;
      var keptCount = 0;
      while (cut > 0) {
        final msg = _mirror[cut - 1];
        final cost =
            LlamaService.estimateTokens(msg.content) + _perMessageOverhead;
        // 最后 2 条保底：当前问题原文不能只存在于摘要里
        if (keptCount >= 2 && used + cost > budget) break;
        used += cost;
        keptCount++;
        cut--;
      }
    }

    final dropped = _mirror.sublist(0, cut);
    final kept = _mirror.sublist(cut);

    // 2) 摘要压实
    var newSummary = _summary;
    if (!force && dropped.isNotEmpty) {
      final summarizer = _summarizer;
      if (summarizer == null) {
        AppLogger.warn('LocalChatClient', '无可用摘要引擎，回落纯丢弃截断');
      } else {
        try {
          final compressed = await summarizer(_summary, dropped);
          if (compressed.isNotEmpty) newSummary = _capSummary(compressed);
        } catch (e) {
          // 回落：丢弃 dropped，保留旧摘要（若有的话）作为背景
          AppLogger.warn('LocalChatClient', '摘要生成失败，回落纯丢弃截断: $e');
        }
      }
    }

    _mirror
      ..clear()
      ..addAll(kept);
    _summary = newSummary;

    // 3) 重建 session：system 提示词 + 摘要卡 + 保留消息
    _session?.dispose();
    _session = await _createSession();
    _session!.addSystem(_systemPrompt);
    var used =
        LlamaService.estimateTokens(_systemPrompt) + _perMessageOverhead;

    if (_summary.isNotEmpty) {
      final card = '【此前对话摘要】\n$_summary';
      _session!.addSystem(card);
      used += LlamaService.estimateTokens(card) + _perMessageOverhead;
    }
    for (final msg in _mirror) {
      if (msg.content.isEmpty) continue;
      if (msg.role == 'user') {
        _session!.addUser(msg.content);
      } else {
        _session!.addAssistant(msg.content);
      }
      used += LlamaService.estimateTokens(msg.content) + _perMessageOverhead;
    }
    _estimatedTokens = used;

    AppLogger.info('LocalChatClient',
        '上下文压缩完成: 摘要${_summary.isEmpty ? '无' : ' ${_summary.length} 字'}, 保留 ${_mirror.length} 条, ~$_estimatedTokens tokens');
  }

  static String _capSummary(String s) {
    final t = s.trim();
    return t.length > 200 ? '${t.substring(0, 200)}…' : t;
  }
}
