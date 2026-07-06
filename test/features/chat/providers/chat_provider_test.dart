import 'package:flutter_test/flutter_test.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/features/chat/providers/chat_provider.dart';

/// ChatProvider 的单元测试
///
/// ChatProvider 负责管理对话的消息列表和轮次计数。
/// 模型未加载时自动回退到 Mock 回复。
void main() {
  group('ChatProvider', () {
    // ============================================================
    // 初始化
    // ============================================================
    test('初始化时包含一条 AI 欢迎消息（轮次 0），且话题相关', () {
      final provider = ChatProvider(topic: '职业发展');

      expect(provider.messages.length, 1);
      expect(provider.messages.first.role, MessageRole.ai);
      expect(provider.messages.first.round, 0);
      expect(provider.messages.first.content, contains('职业'));
    });

    // ============================================================
    // 发送消息
    // ============================================================
    test('发送消息后，消息列表包含用户消息和 AI 回复', () async {
      final provider = ChatProvider(topic: '职业发展');

      await provider.sendMessage('我想转管理');

      expect(provider.messages.length, 3);
      expect(provider.messages[1].role, MessageRole.user);
      expect(provider.messages[1].content, '我想转管理');
      expect(provider.messages[1].round, 1);
      expect(provider.messages[2].role, MessageRole.ai);
    });

    // ============================================================
    // 思考状态
    // ============================================================
    test('Mock 模式下 AI 瞬间回复，isThinking 最终为 false', () async {
      final provider = ChatProvider(topic: 'test');

      expect(provider.isThinking, false);

      await provider.sendMessage('hello');

      expect(provider.isThinking, false);
    });

    // ============================================================
    // 轮次计数
    // ============================================================
    test('每轮对话后 round 计数增加', () async {
      final provider = ChatProvider(topic: 'test');

      // 欢迎消息轮次 0，下一轮用户消息轮次为 1
      expect(provider.round, 1);

      await provider.sendMessage('answer 1');
      expect(provider.round, 2);

      await provider.sendMessage('answer 2');
      expect(provider.round, 3);
    });

    // ============================================================
    // 不可变列表
    // ============================================================
    test('messages 返回不可变列表，防止外部误修改', () {
      final provider = ChatProvider(topic: 'test');

      expect(
        () => provider.messages.add(
          const ChatMessage(
            role: MessageRole.user,
            content: 'hack',
            round: 99,
          ),
        ),
        throwsUnsupportedError,
      );
    });
  });

  // ============================================================
  // ChatMessage 数据模型
  // ============================================================
  group('ChatMessage', () {
    test('字段正确赋值', () {
      const msg = ChatMessage(
        role: MessageRole.user,
        content: 'hello',
        round: 3,
      );

      expect(msg.role, MessageRole.user);
      expect(msg.content, 'hello');
      expect(msg.round, 3);
    });

    test('同一轮的消息可以有 user 和 ai 两条', () {
      const userMsg = ChatMessage(
        role: MessageRole.user,
        content: '我的回答',
        round: 2,
      );
      const aiMsg = ChatMessage(
        role: MessageRole.ai,
        content: 'AI 的追问',
        round: 2,
      );

      expect(userMsg.round, 2);
      expect(aiMsg.round, 2);
    });
  });
}
