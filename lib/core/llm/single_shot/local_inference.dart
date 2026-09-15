import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;

import 'package:zhixing_ai/core/llm/single_shot/think_tag_stripper.dart';

/// 本地推理取回原语（基建共享层）：事件流收敛 + 单次补全样板。
///
/// 从 `features/chat/engine/client/local_chat_client.dart` 平移（Task 1 原语下沉）；
/// 此前摘要器（local_context_policy）与提取器（strategist_extractor）各自手写
/// 一份事件循环，且都漏收 [DoneEvent.trailingText]——本层是唯一实现。

/// [GenerationEvent] 流 → 纯文本 token 流。
///
/// 抽为顶层纯函数才能单测：`EngineChat` 是 `final class`，无法 mock。
/// [TokenEvent] 取 `text`；[DoneEvent] 的 `trailingText` 也必须 yield——引擎会
/// 把它写进回复并登记，丢弃即与引擎内容分叉；其余事件忽略。
Stream<String> eventsToText(Stream<GenerationEvent> events) async* {
  await for (final event in events) {
    if (event is TokenEvent) {
      yield event.text;
    } else if (event is DoneEvent && event.trailingText.isNotEmpty) {
      yield event.trailingText;
    }
  }
}

/// 单次补全样板（本地后端）：在既有 [EngineChat] 上注入 system / user，
/// 收完生成流并释放会话（finally 保证）。
///
/// [chat] 由调用方 `createChat()` 得到——**创建失败的异常语义归调用方**
/// （与平移前两处样板的 try 边界一致）。[stripThink] 为 true 时对收拢结果
/// 施加 [stripThinkTags]（其内部自 trim，返回值恒为去除首尾空白的正文）。
/// `sampler` / `maxTokens` 缺省时透传 SDK 默认值。
Future<String> completeText(
  EngineChat chat, {
  required String system,
  required String user,
  SamplerParams? sampler,
  int? maxTokens,
  bool stripThink = false,
}) async {
  try {
    chat.addSystem(system);
    chat.addUser(user);
    final text =
        await eventsToText(chat.generate(
      sampler: sampler ?? const SamplerParams(),
      maxTokens: maxTokens ?? 512,
    )).join();
    return stripThink ? stripThinkTags(text) : text;
  } finally {
    chat.dispose();
  }
}
