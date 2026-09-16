import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/context/context_assembly.dart';

/// 端侧上下文策略（后端策略）：预算档案 + 度量/摘要注入。
///
/// 装配算法在 [BaseContextPolicy]（无状态），会话态由调用方持有的
/// [ContextState] 承载；本类只提供端侧参数档案：
/// - 度量：**由注入的 [estimator] 决定**（生产为 token 度量
///   `LlamaTemplateEstimator`，归 `core/llm/engine/`——llama 知识不进本域）；
/// - 预算 = `nCtx − 生成上限 − 余量`（端侧物理硬上限）；
/// - 溢出（context full）自愈：从硬留最后 4 条起按预算继续收缩（保底 1 条），
///   保证保留内容真的减到引擎能吃下。
class LocalContextPolicy extends BaseContextPolicy {
  LocalContextPolicy({
    required super.estimator,
    super.summarizer,
    int? budget,
  }) : super(
          budget: budget ?? AppConstants.localInputBudget,
          minKeep: 2,
          overflowKeep: 4,
        );
}
