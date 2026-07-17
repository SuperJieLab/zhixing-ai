import 'package:flutter_test/flutter_test.dart';
import 'package:zhixing_ai/core/models/chat_models.dart';
import 'package:zhixing_ai/features/chat/providers/chat_provider.dart';

ChatProvider makeProvider({String topic = 'test'}) => ChatProvider(topic: topic);

void main() {
  group('ChatProvider', () {
    test('初始化时包含一条 AI 欢迎消息（轮次 0）', () {
      final provider = makeProvider(topic: '职业发展');
      expect(provider.messages.length, 1);
      expect(provider.messages.first.role, MessageRole.ai);
      expect(provider.messages.first.round, 0);
      expect(provider.messages.first.content, contains('职业'));
    });

    test('发送消息后，消息列表包含用户消息和 AI 回复', () async {
      final provider = makeProvider(topic: '职业发展');
      await provider.sendMessage('我想转管理');
      expect(provider.messages.length, 3);
      expect(provider.messages[1].role, MessageRole.user);
      expect(provider.messages[1].content, '我想转管理');
      expect(provider.messages[1].round, 1);
      expect(provider.messages[2].role, MessageRole.ai);
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
      final provider = makeProvider();
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
      const msg = ChatMessage(role: MessageRole.user, content: 'hello', round: 3);
      expect(msg.role, MessageRole.user);
      expect(msg.content, 'hello');
      expect(msg.round, 3);
    });
  });
}
