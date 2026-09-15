import 'package:flutter/foundation.dart';

import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/llm/llm.dart';
import 'package:zhixing_ai/core/model_gateway.dart';

/// 测试用 [Llm] fake（T5 后 `Llm` 收窄为补全面：ask / askJson / readiness /
/// stop / isReady / ensureReady）。
///
/// 对话面的脚本化字段（[onConverse] / [converseCalls]）保留在本类，由
/// [FakeGateway.converse] 写入——业务测试经门面 fake 驱动，不必感知编排。
///
/// **不模拟**后端差异（本地 / 云端）：模式解析是服务内部职责，业务测试
/// 不应感知；服务的模式路由由 `test/core/llm/llm_service_test.dart` 覆盖。
class FakeLlm implements Llm {
  bool ready = false;
  Object? throwOnEnsureReady;

  final ValueNotifier<LlmReadiness> _readiness =
      ValueNotifier<LlmReadiness>(const LlmReadiness.idle());

  /// 脚本化单轮回复流（入参：本轮历史）。缺省为空流（不产出任何 token）。
  /// 由 [FakeGateway.converse] 消费。
  Stream<String> Function(List<ChatMessage> history)? onConverse;

  /// 每轮对话的入参快照（历史 / 人设）。由 [FakeGateway.converse] 写入。
  final List<({List<ChatMessage> history, String systemPrompt})>
      converseCalls = [];

  int ensureReadyCalls = 0;
  int stopCalls = 0;

  @override
  bool get isReady => ready;

  @override
  ValueListenable<LlmReadiness> get readiness => _readiness;

  /// 手动就绪态（页面测试用：驱动 loading / 错误视图）。
  void markReadiness(LlmReadiness value) => _readiness.value = value;

  @override
  Future<void> ensureReady() async {
    ensureReadyCalls++;
    if (throwOnEnsureReady != null) {
      _readiness.value = LlmReadiness.failed(throwOnEnsureReady!);
      throw throwOnEnsureReady!;
    }
    ready = true;
    _readiness.value = const LlmReadiness.ready();
  }

  /// 单次补全：业务测试通常不关心；需要时在子类覆盖。
  @override
  Future<String> ask({
    required String system,
    required String user,
    int? maxTokens,
  }) async =>
      '';

  @override
  Future<Map<String, dynamic>?> askJson({
    required String system,
    required String user,
    int? maxTokens,
  }) async =>
      null;

  @override
  void stop() => stopCalls++;
}

/// 测试用 [ModelGateway] fake（v2 门面）：内部持 [FakeLlm]，公开面全部
/// 委托——业务测试只关心「塞什么、拿到什么」，不感知编排与压缩细节。
class FakeGateway implements ModelGateway {
  final FakeLlm llm;

  FakeGateway({FakeLlm? llm}) : llm = llm ?? FakeLlm();

  @override
  Stream<String> converse(
    List<ChatMessage> history, {
    required String systemPrompt,
  }) {
    llm.converseCalls.add((history: history, systemPrompt: systemPrompt));
    return llm.onConverse?.call(history) ?? const Stream.empty();
  }

  @override
  Future<String> ask({
    required String system,
    required String user,
    int? maxTokens,
  }) =>
      llm.ask(system: system, user: user, maxTokens: maxTokens);

  @override
  Future<Map<String, dynamic>?> askJson({
    required String system,
    required String user,
    int? maxTokens,
  }) =>
      llm.askJson(system: system, user: user, maxTokens: maxTokens);

  @override
  Future<void> ensureReady() => llm.ensureReady();

  @override
  List<ChatMessage> truncateForAsk(
    List<ChatMessage> messages, {
    required String system,
    String? prefix,
    int minKeep = 0,
  }) =>
      messages; // 业务测试不关心截断细节，原样透传

  @override
  void stop() => llm.stop();

  @override
  bool get isReady => llm.isReady;

  @override
  ValueListenable<LlmReadiness> get readiness => llm.readiness;

  @override
  void dispose() {}
}
