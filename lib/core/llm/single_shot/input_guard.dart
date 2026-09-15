/// 单次补全输入预算守门（design D5）。
///
/// v1 的 `ask` / `askJson` 完全绕过上下文装配：本地超 nCtx 无承接（裸异常
/// 或引擎静默截断），云端超长输入无信号（请求无感变大、输出质量无声劣化）。
/// 守门在补全**唯一通道**入口 fail-fast：
///
/// - **不截断**——截断 = 提取任务「成功但错误」，无信号比失败更糟；
/// - **不自愈**——单次调用无可牺牲的历史（输入即全部），超限只能交业务
///   降级（如跳过本轮提取）。
///
/// 度量口径与对话装配对齐：本地 token（`estimateTokens` +
/// 每条 +16 模板开销，同 `LlamaTemplateEstimator`）、云端字符数（同
/// `CharCountEstimator`）。预算取 `AppConstants` 同源常量——本文件属 llm
/// 域，**不 import context 域**（星形依赖红线），度量实现在此内联。
library;

import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/llm/engine/token_estimator.dart';
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
  final (budget, unit) = switch (mode) {
    // 与对话装配同源：本地预算 = nCtx − 生成上限 − 余量（AppConstants 推导）
    ChatMode.local => (AppConstants.localInputBudget, 'token'),
    ChatMode.cloud => (AppConstants.cloudInputBudget, '字符'),
  };
  // 单发请求无消息列表，两条文本各计一次「每条消息」的模板/包装开销
  // （与对话逐条累加口径对齐，宁保守勿漏放：本地 +16/条，云端 +16 字符/条）。
  final measured = switch (mode) {
    ChatMode.local =>
      estimateTokens(system) + estimateTokens(user) + 2 * 16,
    ChatMode.cloud => system.length + user.length + 2 * 16,
  };
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
