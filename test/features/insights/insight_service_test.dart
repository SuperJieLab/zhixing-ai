import 'package:flutter_test/flutter_test.dart';
import 'package:socratic_ai/features/insights/engine/insight_service.dart';
import 'package:socratic_ai/core/engine/llama_service.dart';
import 'package:socratic_ai/core/models/chat_models.dart';

void main() {
  group('InsightService', () {
    late InsightService service;

    setUp(() {
      // engine 为 null 时 analyze 返回空结果（模型未加载场景）
      service = InsightService(LlamaService());
    });

    test('模型未加载时返回空洞察', () async {
      final result = await service.analyze(
        '职业发展',
        [
          const ChatMessage(
            role: MessageRole.ai,
            content: '今天想聊什么？',
            round: 0,
          ),
        ],
      );

      expect(result.coreInsights, isEmpty);
      expect(result.underlyingValues, isEmpty);
      expect(result.contradictionsFound, isEmpty);
      expect(result.nextTopicSuggestion, isNull);
    });

    test('空对话历史返回空洞察', () async {
      final result = await service.analyze('测试', []);

      expect(result.coreInsights, isEmpty);
      expect(result.underlyingValues, isEmpty);
      expect(result.contradictionsFound, isEmpty);
    });
  });
}
