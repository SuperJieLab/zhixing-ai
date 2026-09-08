/**
 * services/sse-parse.js — 上游 SSE（流式）增量解析
 * ==================================================
 *
 * 【这个文件做什么】
 * 把 DeepSeek 流式接口的 SSE 文本，增量地解析成一段段 content delta。
 * 关键点在于「半包」：TCP 一次到达的 chunk 可能正好切断在某一帧中间，
 * 因此必须保留残尾（rest），把它拼到下一个 chunk 前继续解析。
 *
 * 【契约（上游 DeepSeek）】
 *   帧以 "\n\n" 分隔；每帧里只有以 "data: " 开头的行才是有效载荷。
 *   内容形如 data: {"choices":[{"delta":{"content":"字"}}]}
 *   结束帧为 data: [DONE]
 *   首帧可能只有 delta.role、没有 content（要跳过）。
 *
 * 【函数】
 *   extractDeltas(chunk, rest)
 *     chunk — 本次新到达的文本（utf8 字符串）
 *     rest  — 上次未成帧的残尾（首次传 ''）
 *   返回 { deltas, rest, done }
 *     deltas — 每个完整帧里 choices[0].delta.content（跳过空/缺 content、[DONE]）
 *     rest   — 本帧未成帧的残尾，调用方下一次调用时传入
 *     done   — 是否已收到 [DONE]
 *
 * 【健壮性】
 *   某一帧的 JSON 解析失败时，不会让整个解析器抛错——直接跳过该帧，
 *   继续解析后续帧（流式场景下单帧损坏不应中断整条流）。
 */

function extractDeltas(chunk, rest) {
  const buffer = (rest || '') + (chunk || '');
  const parts = buffer.split('\n\n');
  // 最后一段一定是不完整的残尾（可能为空字符串）
  const tail = parts.pop() || '';
  const frames = parts;

  const deltas = [];
  let done = false;

  for (const frame of frames) {
    if (!frame.trim()) continue;
    // 一帧可能包含多行；只取以 "data: " 开头的行
    let dataLine = null;
    for (const line of frame.split('\n')) {
      const trimmed = line.trim();
      if (trimmed.startsWith('data: ')) {
        dataLine = trimmed.slice('data: '.length);
        break; // 取第一条约定的 data 行即可
      }
    }
    if (dataLine === null) continue;

    // 结束帧
    if (dataLine === '[DONE]') {
      done = true;
      continue;
    }

    // 解析 JSON；解析失败则跳过该帧（不抛错）
    let parsed;
    try {
      parsed = JSON.parse(dataLine);
    } catch {
      continue;
    }

    const content = parsed?.choices?.[0]?.delta?.content;
    if (typeof content === 'string' && content.length > 0) {
      deltas.push(content);
    }
    // content 缺失 / 为空 → 跳过（首帧 role-only 的情况）
  }

  return { deltas, rest: tail, done };
}

module.exports = { extractDeltas };
