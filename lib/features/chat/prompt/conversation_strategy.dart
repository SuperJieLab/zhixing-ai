import 'package:zhixing_ai/core/data/models/dashboard_models.dart';

/// 对话策略（本地/云端共享，无引擎/IO 依赖）：
///   - [buildSystemPrompt]：本地/云端共享的唯一人设出处（**留业务**——人设不出 feature）；
///   - [isDuplicate]：相邻问题 LCS 去重（>0.8 判重），命中时**不**追加滚动窗口，
///     避免相邻同问反复触发改写。
///
/// 摘要提示词（`buildSummaryPrompt`）已上移基建：`core/llm/summary_prompt.dart`
/// （属模型能力差异，非业务差异）。
class ConversationStrategy {
  final List<String> _recentQuestions = [];

  /// 与上一问完全相同或 LCS 相似度 > 0.8 → 重复；
  /// 否则记入窗口（容量 5，FIFO）并返回 false。
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

  /// [existingGoals] 非空时追加「用户已有目标」段，引导相似目标建议合并而非新建。
  String buildSystemPrompt({List<Goal> existingGoals = const []}) {
    final goalContext = existingGoals.isEmpty
        ? ''
        : '\n## 用户已有目标\n${existingGoals.map((g) => "- [${g.status.name}] ${g.title}").join('\n')}\n\n如果用户聊到与已有目标相关的话题，可以主动关联。如果新想法与已有目标相似，建议合并而非新建。\n';

    return '''你是知行AI——一个个人目标管理助手。请用简体中文回答用户，可使用 Markdown（如列表、粗体、代码块）组织内容，让回答清晰易读。你的职责是：

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
