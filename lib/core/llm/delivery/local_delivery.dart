import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;
import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/llm/context_assembly.dart';
import 'package:zhixing_ai/core/llm/delivery/chat_delivery.dart';
import 'package:zhixing_ai/core/llm/delivery/tail_dedup.dart';
import 'package:zhixing_ai/core/llm/inference.dart';
import 'package:zhixing_ai/core/llm/think_tag_stripper.dart';
import 'package:zhixing_ai/core/logger.dart';

/// 端侧推理会话窄接口：一份多轮消息列表 + 每轮全量渲染生成。
///
/// 它是 [LocalDelivery] 唯一的 SDK 依赖点，也是**测试接缝**——单测注入 fake
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
class LocalDelivery implements ChatDelivery {
  final ChatSessionFactory _createSession;

  /// 尾部去重（交付内部状态）。
  final TailDeduplicator _dedup = TailDeduplicator();

  /// 当前推理会话。全生命周期只有**一个**（[ensureReady] 创建），此后只 clear + 重放。
  ChatSession? _session;

  LocalDelivery({required ChatSessionFactory sessionFactory})
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
      AppLogger.warn('LocalDelivery', '引擎未就绪');
      yield kLlmNotReadyReply;
      return;
    }

    _syncSession(session, assembled,
        systemPrompt: systemPrompt, nudgeTail: nudgeTail);

    // think 剥离流式输出
    final buffer = StringBuffer();
    var passedThink = false;
    var suppressWhitespace = false;
    try {
      await for (final token
          in session.generate(maxTokens: AppConstants.localMaxTokens)) {
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
      // context full = 真实上下文先于估算撑爆 → 交服务强制收缩自愈
      if (_isContextFullError(e)) {
        AppLogger.warn('LocalDelivery', '上下文撑爆，交服务自愈: $e');
        throw const LlmContextOverflowException();
      }
      AppLogger.error('LocalDelivery', '生成回复失败', e);
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
