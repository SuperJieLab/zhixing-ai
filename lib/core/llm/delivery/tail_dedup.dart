/// 尾部问题去重（**交付实现内部状态**，业务不感知）。
///
/// 从 `features/chat/engine/prompt/conversation_strategy.dart` 的 `isDuplicate`
/// 下沉（Task 3）：它是有状态的滚动窗口，且只被端侧交付的「清空 + 重放」用到；
/// 留在 feature 会造成 `core/llm/delivery` → feature 的反向依赖。
///
/// 命中判重时**不**推进窗口，避免相邻同问反复触发改写。
class TailDeduplicator {
  /// 滚动窗口容量。
  static const int windowSize = 5;

  final List<String> _recentQuestions = [];

  /// 与上一问完全相同或 LCS 相似度 > 0.8 → 重复；
  /// 否则记入窗口（容量 [windowSize]，FIFO）并返回 false。
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
    if (_recentQuestions.length > windowSize) _recentQuestions.removeAt(0);
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
}
