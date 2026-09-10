import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhixing_ai/core/data/conversation_service.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/data/models/conversation.dart';
import 'package:zhixing_ai/core/data/repository/settings_repository.dart';
import 'package:zhixing_ai/features/chat/providers/chat_provider.dart';

/// ChatProvider 错误状态 API 的单元测试
///
/// 需要调用 sendMessage 的测试传入 dummy Conversation(id: 1)，
/// 使 _activeConversationId 不为 null，跳过 startConversation() → DB 操作。
/// 其他测试不传 conversation，正常验证初始状态。
///
/// 注意：每次 makeProvider 新建 Conversation——ChatProvider 会把
/// conversation.messages 当作内部列表就地变更，共享实例会泄漏状态到后续测试。

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
  // ChatProvider 构造时读取 chatCloudMode，须先初始化 SettingsRepository
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await SettingsRepository.instance.initialize();
  });

  ChatProvider makeProvider({String topic = '测试', bool skipDb = true}) =>
      ChatProvider(
        topic: topic,
        conversation: skipDb ? _dummyConv() : null,
        conversationService: _NoopConversationService(),
      );

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
