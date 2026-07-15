/// 去除 LLM 模型的 think/思考 标签及推理内容
///
/// Qwen 和 Bonsai 等模型在输出 JSON 或其他内容时，可能会先输出
/// `<think>...</think>` 或 `<思考>...</思考>` 推理块。
/// 该工具函数用于在 JSON 解析等场景前剥离这些标签，
/// 只保留标签后的实际内容。
///
/// 处理逻辑（与 SocraticPrompter._stripThinkingTags 一致）：
/// 1. 查找 `</think>` 或 `</思考>` 闭合标签，取闭合标签之后的内容
/// 2. 如果以 `<think>` / `<思考>` 开头但无闭合标签，返回空字符串
/// 3. 其他情况原样返回
String stripThinkTags(String text) {
  final trimmed = text.trim();

  final closeIdx1 = trimmed.indexOf('</think>');
  final closeIdx2 = trimmed.indexOf('</思考>');
  final closeIdx = _minIdx(closeIdx1, closeIdx2);
  if (closeIdx != -1) {
    final tagLen = closeIdx == closeIdx1 ? 8 : 6;
    final after = trimmed.substring(closeIdx + tagLen).trim();
    if (after.isNotEmpty) return after;
  }

  if (trimmed.startsWith('<think>') || trimmed.startsWith('<思考>')) {
    return '';
  }

  return trimmed;
}

int _minIdx(int a, int b) {
  if (a == -1) return b;
  if (b == -1) return a;
  return a < b ? a : b;
}
