import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/llm/context_assembly.dart';
import 'package:zhixing_ai/core/llm/summary_prompt.dart';

/// 单次补全的函数形态（后端接缝）：[LlmService] 按模式把 `ask` 委派给其一。
///
/// 测试注入 fake 即可覆盖模式路由与解析容错，无需真实引擎 / 网络。
typedef SingleShotAsk = Future<String> Function({
  required String system,
  required String user,
  int? maxTokens,
});

/// 统一摘要器（策略位④唯一实现）：提示词与输出上限在此，传输走注入的
/// [SingleShotAsk]（服务按当前模式路由到本地引擎 / 云端 BYOK）。
///
/// 此前摘要双端各自摸后端（本地直拿 engine、云端自建 `CloudCompletion`），
/// 与 `ask` 的默认实现逐字重复；收敛为「提示词在此、传输唯一」后，
/// 「怎么调后端」的每个决定（sampler / stripThink / maxTokens / 异常语义）
/// 都只有一处可改。摘要失败异常原样上抛，由 [BaseContextPolicy] 兜底回落
/// （保留旧摘要、被移出消息静默丢弃）。
class SingleShotSummarizer implements ConversationSummarizer {
  /// 摘要请求的输出上限：摘要目标 ≤200 字，512 足够且省钱。
  static const int maxTokens = 512;

  final SingleShotAsk _ask;

  const SingleShotSummarizer(this._ask);

  @override
  Future<String> summarize(
      String previousSummary, List<ChatMessage> evicted) {
    // 提示词与输出上限在此收口；think 剥离由通道实现负责（双端均已在
    // `ask` 的默认实现中处理），本类不做二次加工。
    return _ask(
      system: buildSummaryPrompt(
        previousSummary: previousSummary,
        dropped: evicted
            .map((m) => (role: m.role.name, content: m.content))
            .toList(),
      ),
      user: '请输出摘要。',
      maxTokens: maxTokens,
    );
  }
}
