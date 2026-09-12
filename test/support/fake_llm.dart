import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/llm/context_assembly.dart';
import 'package:zhixing_ai/core/llm/llm.dart';

/// 测试用 [Llm] fake（替代 Task 3 退场的 `ChatClient` fake）。
///
/// 业务侧只认 `converse / ask / askJson / ensureReady / stop / isReady`，
/// 故页面 / Provider / 冒烟测试共用这一个可脚本化实现，无需真实引擎或网络。
///
/// **不模拟**后端差异（本地 / 云端）：模式解析是服务内部职责，业务测试
/// 不应感知；服务的模式路由由 `test/core/llm/llm_service_test.dart` 覆盖。
class FakeLlm implements Llm {
  bool ready = false;
  Object? throwOnEnsureReady;

  /// 脚本化单轮回复流（入参：本轮历史）。缺省为空流（不产出任何 token）。
  Stream<String> Function(List<ChatMessage> history)? onConverse;

  /// 每轮 `converse` 的入参快照（历史 / 人设 / 压缩状态实例）。
  final List<
      ({List<ChatMessage> history, String systemPrompt, ContextState state})>
      converseCalls = [];

  int ensureReadyCalls = 0;
  int stopCalls = 0;

  @override
  bool get isReady => ready;

  @override
  Future<void> ensureReady() async {
    ensureReadyCalls++;
    if (throwOnEnsureReady != null) throw throwOnEnsureReady!;
    ready = true;
  }

  @override
  Stream<String> converse(
    List<ChatMessage> history, {
    required String systemPrompt,
    required ContextState state,
  }) {
    converseCalls
        .add((history: history, systemPrompt: systemPrompt, state: state));
    return onConverse?.call(history) ?? const Stream.empty();
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
