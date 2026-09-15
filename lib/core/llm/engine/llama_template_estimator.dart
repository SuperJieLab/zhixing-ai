import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/context/context_budget.dart';
import 'package:zhixing_ai/core/llm/engine/token_estimator.dart';

/// 端侧度量（策略位②实现，llm 域侧）：token 估算 + 每条消息的 chat template
/// 包装开销。
///
/// 端侧能精确估算是因为我们掌握 llama.cpp 的模板渲染规则；云端不具备这个
/// 前提，故两端的度量单位由各自实现决定。本类持有 llama 知识，因此归
/// `core/llm/engine/`（context 域零后端知识，度量接口由注入传入）。
class LlamaTemplateEstimator extends ContextEstimator {
  /// 每条消息的 template 包装开销（角色标记等），逐条累加。
  static const perMessageOverhead = 16;

  @override
  int estimateMessage(ChatMessage message) =>
      estimateTokens(message.content) + perMessageOverhead;

  @override
  int estimateText(String text) => estimateTokens(text);
}
