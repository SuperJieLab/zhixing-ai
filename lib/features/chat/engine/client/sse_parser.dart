/// SSE 帧缓冲状态机：处理半包/粘包，吐出完整帧的 data 载荷。
/// 帧以 `\n\n` 分隔（容忍 `\r\n`），残帧留内部缓冲等后续 chunk 补齐；
/// `data: [DONE]` 置粘性 [done]，之后 [feed] 恒返回空。
class SseBuffer {
  var _done = false;
  var _rest = '';

  /// 收到 [DONE] 后为 true（粘性）。
  bool get done => _done;

  /// 喂入一个（已 utf8 解码的）chunk，返回其中完整帧的 data 载荷列表。
  List<String> feed(String chunk) {
    if (_done) return const [];
    if (chunk.isEmpty) return const [];

    // 容错：归一化各类换行，避免 CRLF / 残留 \r 干扰帧切分。
    final normalized = chunk.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    _rest = _rest + normalized;
    final pieces = _rest.split('\n\n');
    // split 后最后一个元素要么为空，要么是未完成的残帧 → 残帧留在 rest。
    final complete = pieces.length - 1;
    final frames = pieces.sublist(0, complete);
    _rest = pieces.last;
    // 纯空白残片丢弃，避免污染下一帧。
    if (_rest.trim().isEmpty) _rest = '';

    final out = <String>[];
    for (final frame in frames) {
      final payload = _framePayload(frame);
      if (payload != null) {
        if (payload == '[DONE]') {
          _done = true;
          return out; // 粘性：一旦 done，立即截断后续所有帧（已收载荷照常返回）
        }
        out.add(payload);
      }
    }
    return out;
  }

  /// 取单帧的 data 载荷；无 data 行返回 null；空载荷（`data:` 无内容）也返回 null。
  String? _framePayload(String frame) {
    final dataLines = <String>[];
    for (final rawLine in frame.split('\n')) {
      final line = rawLine.trimRight(); // 容忍行尾空白
      if (line.isEmpty) continue;
      if (line.startsWith(':')) continue; // SSE 注释行
      if (line.startsWith('data:')) {
        var value = line.substring('data:'.length);
        if (value.startsWith(' ')) value = value.substring(1); // 剥一个前导空格
        dataLines.add(value);
      }
      // 其他 SSE 字段（event:/id:/retry:）忽略
    }
    if (dataLines.isEmpty) return null;
    final joined = dataLines.join('\n');
    if (joined.isEmpty) return null; // 空载荷跳过，不返回空串
    return joined;
  }
}
