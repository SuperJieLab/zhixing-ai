import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;
import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/context/context_assembly.dart';
import 'package:zhixing_ai/core/llm/generation/generation.dart';
import 'package:zhixing_ai/core/llm/generation/tail_dedup.dart';
import 'package:zhixing_ai/core/llm/generation/think_stream_filter.dart';
import 'package:zhixing_ai/core/llm/single_shot/local_inference.dart';
import 'package:zhixing_ai/core/logger.dart';

/// 端侧推理会话窄接口：一份多轮消息列表 + 每轮全量渲染生成。
///
/// 它是 [LocalGeneration] 唯一的 SDK 依赖点，也是**测试接缝**——单测注入 fake
/// 即可覆盖重放、think 剥离等路径，无需加载真实模型。生产实现见
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
/// （收敛原语见 `core/llm/single_shot/local_inference.dart` 的 `eventsToText`）。
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

/// 端侧交付实现（llama.cpp 会话）。
///
/// 职责：① 把服务装配好的上下文「清空 + 全量重放」到 [ChatSession]
/// （见 [_syncSession]）；② think 剥离；③ `context full` 抛类型化信号
/// （自愈编排在服务层）。
///
/// **为何每轮重放而非增量补差**：`EngineChat` 收尾会把回复（含 think 原文）自动
/// 登记进自己的列表，增量喂法会有两份必然漂移的列表，只能靠游标 + 位置型补丁
/// 对齐。重放后引擎不再持有权威副本——唯一真相源是业务的 `_messages`，
/// 与云端（每轮现拼现发）同构。成本仅 N 次本地 `List.add`（零 RPC）。
/// 设计见 `docs/plans/2026-09-11-local-stateless-replay-design.md`。
class LocalGeneration implements ChatGeneration {
  final ChatSessionFactory _createSession;

  /// 尾部去重（交付内部状态）。
  final TailDeduplicator _dedup = TailDeduplicator();

  /// 当前推理会话。全生命周期只有**一个**（[ensureReady] 创建），此后只 clear + 重放。
  ChatSession? _session;

  LocalGeneration({required ChatSessionFactory sessionFactory})
      : _createSession = sessionFactory;

  @override
  bool get isReady => _session != null;

  @override
  Future<void> ensureReady() async {
    if (_session != null) return;
    _session = await _createSession();
  }

  @override
  Stream<String> deliver(
    AssembledContext assembled, {
    required String systemPrompt,
    bool nudgeTail = true,
  }) async* {
    final session = _session;
    if (session == null) {
      AppLogger.warn('LocalGeneration', '引擎未就绪');
      yield kLlmNotReadyReply;
      return;
    }

    _syncSession(session, assembled,
        systemPrompt: systemPrompt, nudgeTail: nudgeTail);

    // think 剥离流式输出（状态机在 [ThinkStreamFilter]，本方法只做编排）
    final filter = ThinkStreamFilter();
    final clock = Stopwatch()..start();
    int? firstVisibleMs;
    var yieldedAnything = false;
    var visibleChars = 0;
    try {
      await for (final token
          in session.generate(maxTokens: AppConstants.localMaxTokens)) {
        final out = filter.push(token);
        if (out != null) {
          // 首字延迟 = prefill + 思考段耗时之和，是「半天不出字」的直接指标
          firstVisibleMs ??= clock.elapsedMilliseconds;
          yieldedAnything = true;
          visibleChars += out.length;
          yield out;
        }
      }
      final tail = filter.flush();
      if (tail != null) {
        firstVisibleMs ??= clock.elapsedMilliseconds;
        yieldedAnything = true;
        visibleChars += tail.length;
        yield tail;
      }
      AppLogger.info('LocalGeneration',
          _generationTrace(filter, visibleChars, firstVisibleMs, clock));
      // 思考未闭合却有思考内容 → 整轮都被生成上限截断在思考段里，兜底路径
      // 会把思考残段当正文发出（用户侧表现为「答非所问」）。
      if (filter.thinkChars > 0 && !filter.passedThink) {
        AppLogger.warn('LocalGeneration',
            '思考段未闭合即结束（${filter.thinkChars} 字被当正文兜底），'
            '疑似生成上限被思考吃满');
      }
      // 空输出收口：生成「正常结束」但整轮无任何可见正文（典型：生成上限
      // 全部耗在未闭合的思考段里）。静默空气泡无日志无提示，必须兜底。
      if (!yieldedAnything) {
        AppLogger.warn('LocalGeneration', '本轮生成结束但无可见正文，输出空回复兜底');
        yield kLlmEmptyReply;
      }
    } catch (e) {
      // context full = 真实上下文先于估算撑爆 → 交服务强制收缩自愈
      if (_isContextFullError(e)) {
        AppLogger.warn('LocalGeneration', '上下文撑爆，交服务自愈: $e');
        throw const LlmContextOverflowException();
      }
      AppLogger.error('LocalGeneration', '生成回复失败', e);
      yield kLlmFailureReply;
    }
  }

  @override
  void prime(
    AssembledContext assembled, {
    required String systemPrompt,
    bool nudgeTail = true,
  }) {
    final session = _session;
    if (session == null) return;
    _syncSession(session, assembled,
        systemPrompt: systemPrompt, nudgeTail: nudgeTail);
  }

  @override
  void stop() {
    // 本地流中断由消费方取消订阅完成，无遗留状态需清理：下一轮会 clear 重放。
  }

  @override
  void dispose() {
    _session?.dispose();
    _session = null;
  }

  /// 生成诊断行：四个指标合看即可定位「出字慢 / 被截断」的归属。
  ///
  /// - **首字延迟**：prefill 与思考段耗时之和，是「等半天没反应」的直接指标；
  /// - **think 字数 + 是否闭合**：额度被思考侵占的程度，未闭合 = 已被截断；
  /// - **正文字数**：用户实际得到的量；
  /// - **总耗时**。
  static String _generationTrace(
    ThinkStreamFilter filter,
    int visibleChars,
    int? firstVisibleMs,
    Stopwatch clock,
  ) {
    final first =
        firstVisibleMs == null ? '未出字' : _sec(firstVisibleMs.toDouble());
    return '本轮生成: 首字 $first'
        ' · think ${filter.thinkChars} 字(${filter.passedThink ? '闭合' : '未闭合'})'
        ' / 正文 $visibleChars 字'
        ' · 共 ${_sec(clock.elapsedMilliseconds.toDouble())}'
        '（上限 ${AppConstants.localMaxTokens} token）';
  }

  static String _sec(double ms) => '${(ms / 1000).toStringAsFixed(1)}s';

  /// 无状态重放：清空消息列表，再按「人设 → 摘要卡 → 装配结果」全量重建，
  /// 使引擎内列表恒等于本轮装配结果。本类与 SDK 之间唯一的会话同步点。
  ///
  /// [nudgeTail] 为尾部用户消息的去重改写开关（上一问高度相似 → 提示换角度）。
  /// `isDuplicate` 有状态（会把问题记入滚动窗口），故同一轮交付内只允许施加
  /// 一次：溢出收缩后的二次重放（服务的 [prime]）须传 `false`。
  void _syncSession(
    ChatSession session,
    AssembledContext assembled, {
    required String systemPrompt,
    bool nudgeTail = true,
  }) {
    session.clear();
    session.addSystem(systemPrompt);
    final summaryCard = assembled.summaryCard;
    if (summaryCard != null) {
      session.addSystem(summaryCard);
    }
    final messages = assembled.messages;
    // 新会话首问（无摘要 + 仅一条窗口消息）→ 清空判重窗口：交付实现自
    // Task 3 起与 App 同寿命（不再随 ChatProvider 每会话新建），判重窗口
    // 若不重置，上一会话的最后一问会污染新会话首问的去重判定。
    if (summaryCard == null && messages.length <= 1) _dedup.reset();
    final last = messages.length - 1;
    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];
      if (msg.content.isEmpty) continue;
      if (msg.role == MessageRole.user) {
        final rewritten =
            nudgeTail && i == last && _dedup.isDuplicate(msg.content);
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
