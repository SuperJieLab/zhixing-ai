import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;
import 'package:zhixing_ai/core/llm/inference.dart';

/// 原语单测：`eventsToText`（SDK 事件流 → 纯文本 token 流）。
///
/// 这是全 App 唯一的事件循环实现（提取器 / 摘要器经 `completeText` 共享），
/// 故放在 `core/llm` 同构镜像位置。
///
/// `completeText` 的端到端（含 finally 释放）不可单测：`LlamaEngine` /
/// `EngineChat` 均 `final class` 无法 fake，改由 `tool/llama_integration_test.dart`
/// 与真机冒烟覆盖。

TokenEvent _token(String text) =>
    TokenEvent(id: 1, bytes: Uint8List(0), text: text, position: 0);

void main() {
  group('eventsToText（SDK 事件流 → 文本 token 流）', () {
    test('TokenEvent 逐条输出；DoneEvent.trailingText 非空时补充', () async {
      final out = await eventsToText(Stream.fromIterable([
        _token('正文'),
        const DoneEvent(
          reason: StopMaxTokens(),
          generatedCount: 1,
          committedPosition: 1,
          trailingText: '残留片段',
        ),
      ])).toList();

      expect(out, ['正文', '残留片段']);
    });

    test('DoneEvent.trailingText 为空时不产生空事件', () async {
      final out = await eventsToText(Stream.fromIterable([
        _token('正文'),
        const DoneEvent(
          reason: StopMaxTokens(),
          generatedCount: 1,
          committedPosition: 1,
        ),
      ])).toList();

      expect(out, ['正文']);
    });

    test('ShiftEvent 被忽略（不参与文本流）', () async {
      final out = await eventsToText(Stream.fromIterable([
        const ShiftEvent(nKeep: 1, nDiscard: 2, newPosition: 3),
        _token('正文'),
      ])).toList();

      expect(out, ['正文']);
    });
  });
}
