import 'package:flutter_test/flutter_test.dart';
import 'package:zhixing_ai/core/models/chat_models.dart';
import 'package:zhixing_ai/core/models/conversation.dart';
import 'package:zhixing_ai/features/chat/providers/chat_provider.dart';

/// ChatProvider 错误状态 API 的单元测试
///
/// 需要调用 sendMessage 的测试传入 dummy Conversation(id: 1)，
/// 使 _activeConversationId 不为 null，跳过 startConversation() → DB 操作。
/// 其他测试不传 conversation，正常验证初始状态。

final _dummyConv = Conversation(
  id: 1,
  topic: '测试',
  createdAt: DateTime.now(),
  updatedAt: DateTime.now(),
);

ChatProvider makeProvider({String topic = '测试', bool skipDb = true}) =>
    ChatProvider(topic: topic, conversation: skipDb ? _dummyConv : null);

void main() {
  group('ChatProvider error state', () {
    test('hasModelError 初始为 false', () {
      final provider = makeProvider(skipDb: false);
      expect(provider.hasModelError, false);
    });

    test('modelError 初始为 null', () {
      final provider = makeProvider(skipDb: false);
      expect(provider.modelError, isNull);
    });

    test('hasModelError 与 modelError 一致', () {
      final provider = makeProvider(skipDb: false);
      expect(provider.hasModelError, false);
      expect(provider.modelError, isNull);
    });

    test('error（推理错误）初始为 null', () {
      final provider = makeProvider(skipDb: false);
      expect(provider.error, isNull);
    });

    test('clearError 可正常调用且不崩溃', () {
      final provider = makeProvider(skipDb: false);
      expect(provider.error, isNull);
      provider.clearError();
      expect(provider.error, isNull);
    });

    test('retryLoadModel 方法存在', () {
      final provider = makeProvider(skipDb: false);
      final result = provider.retryLoadModel();
      expect(result, isA<Future<void>>());
    });
  });

  group('ChatProvider 对话错误处理', () {
    test('sendMessage 在无引擎时使用 Mock 回复且不设置 error', () async {
      // skipDb: true → 传入 dummyConv，绕过 DB
      final provider = makeProvider();
      await provider.sendMessage('你好');
      // dummyConv 的 messages 为空，sendMessage 后应有 用户 + AI(Mock) = 2 条
      expect(provider.messages.length, greaterThanOrEqualTo(2));
      expect(provider.messages.last.role, MessageRole.ai);
      expect(provider.error, isNull);
    });
  });
}
