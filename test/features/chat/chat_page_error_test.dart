import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhixing_ai/core/data/conversation_service.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/data/models/conversation.dart';
import 'package:zhixing_ai/core/data/repository/settings_repository.dart';
import 'package:zhixing_ai/features/chat/providers/chat_provider.dart';

import '../../support/fake_llm.dart';

/// ChatProvider 对话错误与兜底行为的单元测试
///
/// 需要调用 sendMessage 的测试传入 dummy Conversation(id: 1)，
/// 使 _activeConversationId 不为 null，跳过 startConversation() → DB 操作。
///
/// 模型加载相关状态（isModelLoading / modelError / retryLoadModel）已随
/// Task 4 移交服务（llm.readiness），不再属于 Provider。

Conversation _dummyConv() => Conversation(
      id: 1,
      topic: '测试',
      // 显式给可增长列表：默认值是 const []（不可变），
      // ChatProvider 会把它当作内部消息列表就地 add，会抛 UnsupportedError
      messages: <ChatMessage>[],
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

/// no-op 持久化：跳过 sendMessage finally 里的 saveMessages → DB 落库
class _NoopConversationService extends ConversationService {
  @override
  Future<void> saveMessages(
      int conversationId, List<ChatMessage> messages) async {}
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await SettingsRepository.instance.initialize();
  });

  ChatProvider makeProvider({String topic = '测试', FakeLlm? llm}) =>
      ChatProvider(
        topic: topic,
        conversation: _dummyConv(),
        conversationService: _NoopConversationService(),
        llm: llm ?? FakeLlm(),
      );

  group('ChatProvider error state', () {
    test('error（推理错误）初始为 null', () {
      final provider = makeProvider();
      expect(provider.error, isNull);
    });

    test('clearError 可正常调用且不崩溃', () {
      final provider = makeProvider();
      expect(provider.error, isNull);
      provider.clearError();
      expect(provider.error, isNull);
    });
  });

  group('ChatProvider 对话错误处理', () {
    test('后端未就绪时使用 Mock 回复且不设置 error', () async {
      // FakeLlm 默认 ready=false → sendMessage 走 Mock 兜底
      final provider = makeProvider();
      await provider.sendMessage('你好');
      expect(provider.messages.length, 2); // user + AI(Mock)
      expect(provider.messages.last.role, MessageRole.ai);
      expect(provider.messages.last.content, isNotEmpty);
      expect(provider.error, isNull);
    });

    test('后端就绪后走真实推理（converse 被调用）', () async {
      final llm = FakeLlm()..ready = true;
      llm.onConverse = (_) => Stream.value('真实回复');
      final provider = makeProvider(llm: llm);

      await provider.sendMessage('你好');

      expect(llm.converseCalls, hasLength(1));
      expect(provider.messages.last.content, '真实回复');
      expect(provider.error, isNull);
    });
  });
}
