import 'package:flutter_test/flutter_test.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/models/conversation.dart';

void main() {
  group('Conversation 模型序列化', () {
    test('toMap / fromMap 往返一致（含 messages + insight）', () {
      final conv = Conversation(
        id: 1,
        topic: '职业发展',
        messages: [
          const ChatMessage(
            role: MessageRole.ai,
            content: '你好，你想聊什么？',
            round: 0,
          ),
          const ChatMessage(
            role: MessageRole.user,
            content: '我想聊聊职业规划',
            round: 1,
          ),
        ],
        insight: const InsightResult(
          coreInsights: ['重视安全', '渴望自由'],
          underlyingValues: ['安全感', '自由'],
          contradictionsFound: ['想自由但害怕风险'],
          nextTopicSuggestion: '风险管理',
        ),
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        isFavorite: true,
      );

      final map = conv.toMap();
      final restored = Conversation.fromMap(map);

      expect(restored.id, 1);
      expect(restored.topic, '职业发展');
      expect(restored.isFavorite, true);
      expect(restored.status, 'active');
      expect(restored.messages.length, 2);
      expect(restored.messages[0].role, MessageRole.ai);
      expect(restored.messages[0].content, '你好，你想聊什么？');
      expect(restored.messages[1].role, MessageRole.user);
      expect(restored.totalRounds, 1);
      expect(restored.hasInsight, true);
      expect(restored.insight!.coreInsights, ['重视安全', '渴望自由']);
      expect(restored.insight!.underlyingValues, ['安全感', '自由']);
      expect(restored.insight!.contradictionsFound, ['想自由但害怕风险']);
      expect(restored.insight!.nextTopicSuggestion, '风险管理');
    });

    test('toMap / fromMap 往返一致（无 messages + 无 insight）', () {
      final conv = Conversation(
        topic: '测试话题',
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );

      final map = conv.toMap();
      final restored = Conversation.fromMap(map);

      expect(restored.topic, '测试话题');
      expect(restored.messages, isEmpty);
      expect(restored.insight, isNull);
      expect(restored.totalRounds, 0);
      expect(restored.hasInsight, false);
      expect(restored.isFavorite, false);
      expect(restored.status, 'active');
    });

    test('copyWith 正确更新字段', () {
      final original = Conversation(
        topic: '原话题',
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );

      final updated = original.copyWith(
        topic: '新话题',
        isFavorite: true,
        status: 'completed',
      );

      expect(updated.topic, '新话题');
      expect(updated.isFavorite, true);
      expect(updated.status, 'completed');
      // 未修改的字段保持不变
      expect(updated.messages, isEmpty);
      expect(updated.insight, isNull);
    });

    test('totalRounds 只统计用户消息', () {
      final conv = Conversation(
        topic: '测试',
        messages: [
          const ChatMessage(role: MessageRole.ai, content: '欢迎', round: 0),
          const ChatMessage(role: MessageRole.user, content: '你好', round: 1),
          const ChatMessage(role: MessageRole.ai, content: '追问', round: 1),
          const ChatMessage(
              role: MessageRole.user, content: '回答', round: 2),
          const ChatMessage(role: MessageRole.ai, content: '再追问', round: 2),
        ],
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );

      expect(conv.totalRounds, 2); // 只有 2 条用户消息
    });

    test('id 为 null 时 toMap 不含 id', () {
      final conv = Conversation(
        topic: '测试',
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );

      final map = conv.toMap();
      expect(map.containsKey('id'), false);
    });

    test('insight_json 为空字符串时不抛异常', () {
      final map = {
        'id': 1,
        'topic': '测试',
        'status': 'active',
        'is_favorite': 0,
        'messages_json': '[{"role":"ai","content":"你好","round":0}]',
        'insight_json': '',
        'created_at': '2026-01-01T00:00:00.000',
        'updated_at': '2026-01-01T00:00:00.000',
      };

      final conv = Conversation.fromMap(map);
      expect(conv.insight, isNull);
    });
  });
}
