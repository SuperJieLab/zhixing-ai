/// 端侧 token 估算（纯函数，不依赖引擎）
///
/// 中文 CJK 字符 ≈ 1.5 tokens，其他字符 ≈ 0.25 tokens。
/// 与 llama.cpp 实际分词有偏差，但作为「预算守门 + 装配装箱」的统一口径足够。
///
/// **消费方必须共用同一口径**：
/// - `LlamaTemplateEstimator`（对话装配度量，`llm/engine/`）
/// - `ensureInputWithinBudget`（单次补全守门，`llm/single_shot/`）
///
/// 故独立成纯函数而非挂在 [LlamaService] 上——引擎池单例是资源持有者，
/// 与"度量"无关，挂在它上面会让纯函数消费方被迫依赖整个引擎。
int estimateTokens(String text) {
  int chineseCount = 0;
  int otherCount = 0;
  for (final char in text.runes) {
    if ((char >= 0x4E00 && char <= 0x9FFF) ||
        (char >= 0x3400 && char <= 0x4DBF) ||
        (char >= 0x3000 && char <= 0x303F)) {
      chineseCount++;
    } else {
      otherCount++;
    }
  }
  return (chineseCount * 1.5 + otherCount * 0.25).ceil();
}
