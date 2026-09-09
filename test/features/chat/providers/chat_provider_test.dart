import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhixing_ai/core/engine/conversation_service.dart';
import 'package:zhixing_ai/core/models/chat_models.dart';
import 'package:zhixing_ai/core/models/conversation.dart';
import 'package:zhixing_ai/core/repository/settings_repository.dart';
import 'package:zhixing_ai/features/chat/providers/chat_provider.dart';

/// ChatProvider 单元测试
///
/// 传入 dummy Conversation(id: 1) 使 _activeConversationId 不为 null，
/// sendMessage() 就不会触发 startConversation() → DB 操作。
/// 避免在 macOS 测试环境中依赖 sqflite（需要 sqflite_common_ffi）。
///
/// 注意：每次 makeProvider 新建 Conversation——ChatProvider 会把
/// conversation.messages 当作内部列表就地变更，共享实例会泄漏状态到后续测试。

Conversation _dummyConv() => Conversation(
      id: 1,
      topic: 'test',
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

  ChatProvider makeProvider({String topic = 'test', bool skipDb = true}) =>
      ChatProvider(
        topic: topic,
        conversation: skipDb ? _dummyConv() : null,
        conversationService: _NoopConversationService(),
      );

  group('ChatProvider', () {
    test('初始化时包含一条 AI 欢迎消息（轮次 0）', () {
      // skipDb: false → 不传 conversation，使用 _buildWelcome
      final provider = makeProvider(topic: '职业发展', skipDb: false);
      expect(provider.messages.length, 1);
      expect(provider.messages.first.role, MessageRole.ai);
      expect(provider.messages.first.round, 0);
      expect(provider.messages.first.content, contains('职业'));
    });

    test('发送消息后，消息列表包含用户消息和 AI 回复', () async {
      final provider = makeProvider(topic: '职业发展');
      await provider.sendMessage('我想转管理');
      // 恢复会话路径不加欢迎语：仅本轮 user + AI 两条
      expect(provider.messages.length, 2);
      expect(provider.messages[0].role, MessageRole.user);
      expect(provider.messages[0].content, '我想转管理');
      expect(provider.messages[0].round, 1);
      expect(provider.messages[1].role, MessageRole.ai);
    });

    test('Mock 模式下 isThinking 最终为 false', () async {
      final provider = makeProvider();
      expect(provider.isThinking, false);
      await provider.sendMessage('hello');
      expect(provider.isThinking, false);
    });

    test('每轮对话后 round 计数增加', () async {
      final provider = makeProvider();
      expect(provider.round, 1);
      await provider.sendMessage('answer 1');
      expect(provider.round, 2);
      await provider.sendMessage('answer 2');
      expect(provider.round, 3);
    });

    test('messages 返回不可变列表', () {
      final provider = makeProvider(skipDb: false);
      expect(
        () => provider.messages.add(const ChatMessage(
          role: MessageRole.user, content: 'hack', round: 99,
        )),
        throwsUnsupportedError,
      );
    });
  });

  group('ChatMessage', () {
    test('字段正确赋值', () {
      const msg =
          ChatMessage(role: MessageRole.user, content: 'hello', round: 3);
      expect(msg.role, MessageRole.user);
      expect(msg.content, 'hello');
      expect(msg.round, 3);
    });
  });
}
