import 'package:flutter_test/flutter_test.dart';
import 'package:socratic_ai/features/topics/providers/topic_provider.dart';

void main() {
  group('TopicProvider', () {
    test('initial state has null selected topic', () {
      final provider = TopicProvider();
      expect(provider.selectedTopic, isNull);
      expect(provider.customTopic, isEmpty);
    });

    test('selectTopic updates selected topic title', () {
      final provider = TopicProvider();
      provider.selectTopic('职业发展');
      expect(provider.selectedTopic, '职业发展');
    });

    test('setCustomTopic updates custom topic', () {
      final provider = TopicProvider();
      provider.setCustomTopic('如何处理焦虑');
      expect(provider.customTopic, '如何处理焦虑');
    });
  });
}
