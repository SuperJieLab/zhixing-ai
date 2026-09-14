/// 单次补全输入预算守门（design D5）。
///
/// v1 的 `ask` / `askJson` 完全绕过 `ContextPolicy`：本地超 nCtx 无承接
/// （裸异常或引擎静默截断），云端超长输入无信号（请求无感变大、输出质量
/// 无声劣化）。守门在补全**唯一通道**入口 fail-fast：
///
/// - **不截断**——截断 = 提取任务「成功但错误」，无信号比失败更糟；
/// - **不自愈**——单次调用无可牺牲的历史（输入即全部），超限只能交业务
///   降级（如跳过本轮提取）。
///
/// 度量口径与 `converse` 对齐：本地 `LlamaTemplateEstimator`（同 nCtx 推导
/// 的 `localInputBudget`）、云端 `CharCountEstimator` 对 `cloudInputBudget`。
library;

import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/llm/cloud_context_policy.dart';
import 'package:zhixing_ai/core/llm/context_budget.dart';
import 'package:zhixing_ai/core/llm/llm.dart';
import 'package:zhixing_ai/core/logger.dart';

/// 单次补全输入超预算（fail-fast，业务决定降级）。
class GatewayInputOverflowException implements Exception {
  /// 后端模式（local / cloud）。
  final ChatMode mode;

  /// 输入度量值（token / 字符，随模式）。
  final int measured;

  /// 该模式的输入预算上限（单位同 [measured]）。
  final int budget;

  const GatewayInputOverflowException({
    required this.mode,
    required this.measured,
    required this.budget,
  });

  @override
  String toString() =>
      'GatewayInputOverflowException(单次补全输入超预算: ${mode.name} '
      '$measured / $budget，请精简输入或交业务降级)';
}

/// 守门入口：度量 `system + user`，超该模式预算即抛。
///
/// 供 `LlmService.ask` / `askJson` 共同入口施加（单点，双路径自动覆盖）。
/// 纯函数、无状态；不发生任何网络 / 引擎动作。
void ensureInputWithinBudget({
  required ChatMode mode,
  required String system,
  required String user,
}) {
  final (estimator, budget, unit) = switch (mode) {
    // 与 converse 同源：本地预算 = nCtx − 生成上限 − 余量（AppConstants 推导）
    ChatMode.local => (
        LlamaTemplateEstimator(),
        AppConstants.localInputBudget,
        'token',
      ),
    ChatMode.cloud => (
        CharCountEstimator(),
        AppConstants.cloudInputBudget,
        '字符',
      ),
  };
  // 单发请求无消息列表，两条文本各计一次「每条消息」的模板/包装开销
  // （与 converse 逐条累加口径对齐，宁保守勿漏放）。
  final measured = estimator.estimateText(system) +
      estimator.estimateText(user) +
      2 * estimatorPerMessageOverhead(estimator);
  if (measured > budget) {
    AppLogger.warn('InputGuard', '单次补全输入超预算（${mode.name}）：'
        '$measured / $budget $unit');
    throw GatewayInputOverflowException(
      mode: mode,
      measured: measured,
      budget: budget,
    );
  }
}

/// 取实现类的每条消息开销常量（无反射的轻量分派）。
int estimatorPerMessageOverhead(ContextEstimator estimator) {
  if (estimator is LlamaTemplateEstimator) {
    return LlamaTemplateEstimator.perMessageOverhead;
  }
  if (estimator is CharCountEstimator) {
    return CharCountEstimator.perMessageOverhead;
  }
  return 0;
}
