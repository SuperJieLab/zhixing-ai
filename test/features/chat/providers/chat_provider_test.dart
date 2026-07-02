import 'package:flutter_test/flutter_test.dart';
import 'package:socratic_ai/features/chat/providers/chat_provider.dart';

/// ChatProvider 的单元测试
///
/// ChatProvider 负责管理对话的消息列表和轮次计数。
/// MVP 阶段使用 Mock 数据模拟 AI 回复，Day 3 会替换为真正的 LLM 推理。
///
/// ## 核心概念
/// - [ChatMessage]：一条消息（谁说的、说了什么、第几轮）
/// - [ChatProvider]：管理整个对话流的 Provider
/// - Mock 回复：用预设的 5 句话轮换，模拟苏格拉底式追问
void main() {
  group('ChatProvider', () {
    // ============================================================
    // 测试 1：初始化时自动生成欢迎消息
    // ============================================================
    test('初始化时包含一条 AI 欢迎消息，且话题相关', () {
      // 创建一个「职业发展」话题的 ChatProvider
      final provider = ChatProvider(topic: '职业发展');

      // 断言：消息列表有 1 条（欢迎消息）
      expect(provider.messages.length, 1);

      // 断言：第一条消息是 AI 说的
      expect(provider.messages.first.role, 'ai');

      // 断言：欢迎消息内容包含话题相关关键词
      // 注意：欢迎消息里写的是「职业方向」而不是「职业发展」，
      // 所以用 contains('职业') 做宽泛匹配
      expect(provider.messages.first.content, contains('职业'));
    });

    // ============================================================
    // 测试 2：发送消息后增加用户消息和 AI 回复
    // ============================================================
    test('发送消息后，消息列表包含用户消息和 AI 回复', () {
      final provider = ChatProvider(topic: '职业发展');

      // 用户发送一条消息
      provider.sendMessage('我想转管理');

      // 断言：消息总数为 3（欢迎 + 用户消息 + AI 回复）
      expect(provider.messages.length, 3);

      // 断言：第 2 条（索引 1）是用户消息
      expect(provider.messages[1].role, 'user');
      expect(provider.messages[1].content, '我想转管理');

      // 断言：第 3 条（索引 2）是 AI 回复
      expect(provider.messages[2].role, 'ai');
    });

    // ============================================================
    // 测试 3：Mock 模式下，AI 瞬间回复（不需要等待）
    // ============================================================
    test('Mock 模式下 AI 瞬间回复，isThinking 始终为 false', () {
      final provider = ChatProvider(topic: 'test');

      // 初始状态：不在思考中
      expect(provider.isThinking, false);

      // 发送消息
      provider.sendMessage('hello');

      // Mock 模式下消息立即完成，所以还是 false
      // 注意：Day 3 接入真实 LLM 后，这里的行为会变化
      expect(provider.isThinking, false);
    });

    // ============================================================
    // 测试 4：每次 AI 回复后轮次计数增加
    // ============================================================
    test('每轮对话后 round 计数增加', () {
      final provider = ChatProvider(topic: 'test');

      // 初始轮次：1（欢迎消息算第 1 轮）
      expect(provider.round, 1);

      // 用户发送第一轮回复
      provider.sendMessage('answer 1');

      // AI 回复后，轮次变为 2
      expect(provider.round, 2);

      // 再发送一轮
      provider.sendMessage('answer 2');

      // 轮次变为 3
      expect(provider.round, 3);
    });

    // ============================================================
    // 测试 5：messages 返回的是不可变列表（防止外部直接修改）
    // ============================================================
    test('messages 返回不可变列表，防止外部误修改', () {
      final provider = ChatProvider(topic: 'test');

      // 尝试修改返回的列表应该抛出异常
      expect(
        () => provider.messages.add(
          const ChatMessage(role: 'user', content: 'hack', round: 99),
        ),
        throwsUnsupportedError,
      );
    });
  });

  // ============================================================
  // ChatMessage 数据模型的测试
  // ============================================================
  group('ChatMessage', () {
    test('ChatMessage 的字段正确赋值', () {
      // 创建一个消息实例
      const msg = ChatMessage(role: 'user', content: 'hello', round: 3);

      // 断言：三个字段都正确
      expect(msg.role, 'user');
      expect(msg.content, 'hello');
      expect(msg.round, 3);
    });

    test('同一轮的消息可以有 user 和 ai 两条', () {
      // 第 2 轮对话中，用户和 AI 的 round 值相同
      const userMsg = ChatMessage(role: 'user', content: '我的回答', round: 2);
      const aiMsg = ChatMessage(role: 'ai', content: 'AI 的追问', round: 2);

      expect(userMsg.round, 2);
      expect(aiMsg.round, 2);
    });
  });
}
