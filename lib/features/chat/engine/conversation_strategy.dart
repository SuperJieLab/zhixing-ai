import 'package:zhixing_ai/core/models/dashboard_models.dart';

/// 对话策略（本地/云端共享）
///
/// 从 StrategistPrompter 抽出的纯逻辑部分，无引擎/IO 依赖：
///   - [buildSystemPrompt]：助手人设 + 已有目标上下文。本地在 initialize 时
///     注入 session；云端（②）将随请求体发送、由服务端拼装，人设对等。
///   - [isDuplicate]：相邻问题 LCS 相似度去重（>0.8 判重）。判重命中时**不**
///     追加到滚动窗口，避免相邻同问反复触发改写。
///
/// 有状态（[_recentQuestions]），每个 ChatClient 实例持有一份。
class ConversationStrategy {
  final List<String> _recentQuestions = [];

  /// 判断 [input] 是否与最近一次提问重复。
  ///
  /// 规则（与原 StrategistPrompter 一致）：
  ///   - 与上一问完全相同 → 重复；
  ///   - 与上一问 LCS 相似度 > 0.8 → 重复；
  ///   - 否则记入窗口（容量 5，FIFO）并返回 false。
  bool isDuplicate(String input) {
    final trimmed = input.trim();
    if (_recentQuestions.isEmpty) {
      _recentQuestions.add(trimmed);
      return false;
    }

    if (_recentQuestions.last == trimmed) return true;

    final lcs = _lcsSimilarity(_recentQuestions.last, trimmed);
    if (lcs > 0.8) return true;

    _recentQuestions.add(trimmed);
    if (_recentQuestions.length > 5) _recentQuestions.removeAt(0);
    return false;
  }

  double _lcsSimilarity(String a, String b) {
    final m = a.length;
    final n = b.length;
    final dp = List.generate(m + 1, (_) => List.filled(n + 1, 0));
    for (var i = 1; i <= m; i++) {
      for (var j = 1; j <= n; j++) {
        if (a[i - 1] == b[j - 1]) {
          dp[i][j] = dp[i - 1][j - 1] + 1;
        } else {
          dp[i][j] =
              dp[i - 1][j] > dp[i][j - 1] ? dp[i - 1][j] : dp[i][j - 1];
        }
      }
    }
    final lcsLen = dp[m][n];
    return lcsLen / (m > n ? m : n);
  }

  /// 助手系统提示词
  ///
  /// [existingGoals] 非空时追加「用户已有目标」段，引导 LLM 关联话题、
  /// 相似目标建议合并而非新建。
  String buildSystemPrompt({List<Goal> existingGoals = const []}) {
    final goalContext = existingGoals.isEmpty
        ? ''
        : '\n## 用户已有目标\n${existingGoals.map((g) => "- [${g.status.name}] ${g.title}").join('\n')}\n\n如果用户聊到与已有目标相关的话题，可以主动关联。如果新想法与已有目标相似，建议合并而非新建。\n';

    return '''你是助手。用户来找你商量事情，你的职责是：

1. 先理解用户的真实处境和核心诉求
2. 帮用户把模糊的问题拆解成清晰的子问题
3. 给出具体的分析和可执行的策略建议
4. 区分"用户自己能做的"和"需要外部条件配合的"
5. 在适当时候追问，帮助用户想得更深
$goalContext
风格要求：
- 像朋友一样真诚，不端着
- 给具体建议，不说空话
- 分析为什么这样建议，让用户理解背后的逻辑
- 每次回复控制在 3-5 句话内，简洁有力
- 目标需要用户确认后才能生效，不要假设目标已定''';
  }
}
