import 'package:zhixing_ai/core/llm/single_shot/think_tag_stripper.dart';

/// 流式 think 剥离（[LocalGeneration] 专用，与非流式 [stripThinkTags] 同口径）。
///
/// 从 `LocalGeneration.deliver` 内联状态机抽出（2026-09-13）：三阶段
/// ① think 未闭合 → 缓冲并探测闭合标签；② 闭合后吸收前导空白；
/// ③ 正文原样透传（buffer 同步累积，供 [flush] 兜底）。
class ThinkStreamFilter {
  final StringBuffer _buffer = StringBuffer();
  bool _passedThink = false;
  bool _suppressWhitespace = false;

  /// 被吞掉的思考段字符数（**仅观测用**）。
  ///
  /// 端侧额度被思考侵占时的唯一可见指标：llama.cpp 的 ChatML 渲染绕过了
  /// Qwen 模板的 `enable_thinking` 开关（见 `AppConstants.localMaxTokens`），
  /// 模型可能自发思考，思考越长正文越短——日志里比对两者即可判断。
  int _thinkChars = 0;

  int get thinkChars => _thinkChars;

  /// think 段是否已闭合（**观测用**）。
  ///
  /// 与 [thinkChars] 合看即可区分三种收尾：无思考（0 字 + 未闭合）、
  /// 思考正常结束（N 字 + 闭合）、思考**被生成上限截断**（N 字 + 未闭合，
  /// 此时 [flush] 会把思考残段当正文兜底发出——「答非所问」的来源）。
  bool get passedThink => _passedThink;

  /// 喂入一个 token，返回需要对外发出的文本（无需发出时为 null）。
  String? push(String token) {
    // ③ 正文透传：token 必须同步写 buffer，flush 兜底依赖其完整性。
    if (_passedThink) {
      _buffer.write(token);
      return token;
    }

    // ② 吸收 </think> 之后的空白
    if (_suppressWhitespace) {
      _buffer.write(token);
      final trimmed = _buffer.toString().trimLeft();
      if (trimmed.isEmpty) return null;
      _suppressWhitespace = false;
      _buffer.clear();
      _buffer.write(trimmed);
      return trimmed;
    }

    // ① think 未闭合：缓冲并探测闭合标签
    _buffer.write(token);
    _thinkChars += token.length;
    final text = _buffer.toString();
    final closeIdx = _indexOfThinkClose(text);
    if (closeIdx < 0) return null;

    _passedThink = true;
    _suppressWhitespace = true;
    final after = text.substring(closeIdx).trimLeft();
    _buffer.clear();
    _buffer.write(after);
    if (after.isEmpty) return null;
    _suppressWhitespace = false;
    return after;
  }

  /// 流结束收尾：非思考模式（全程无闭合标签）时缓冲内容即正文，
  /// 不发出会空气泡。已在正文阶段则无兜底可发。
  String? flush() {
    if (_passedThink) return null;
    final fullReply = stripThinkTags(_buffer.toString());
    return fullReply.isEmpty ? null : fullReply;
  }

  /// 闭合标签的**结束下标**（取 `</think>` 优先，其次 `</思考>`）；未找到为 -1。
  static int _indexOfThinkClose(String text) {
    final i1 = text.indexOf('</think>');
    if (i1 >= 0) return i1 + '</think>'.length;
    final i2 = text.indexOf('</思考>');
    if (i2 >= 0) return i2 + '</思考>'.length;
    return -1;
  }
}
