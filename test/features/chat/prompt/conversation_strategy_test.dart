import 'package:test/test.dart';
import 'package:zhixing_ai/core/data/models/dashboard_models.dart';
import 'package:zhixing_ai/features/chat/prompt/conversation_strategy.dart';

Goal _goal(String title, [GoalStatus status = GoalStatus.active]) => Goal(
      title: title,
      status: status,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

void main() {
  group('buildSystemPrompt', () {
    test('无 goals → 统一人设（含知行AI/中文/Markdown），不含目标段', () {
      final prompt = ConversationStrategy().buildSystemPrompt();
      expect(prompt, contains('你是知行AI'));
      expect(prompt, contains('简体中文'));
      expect(prompt, contains('Markdown'));
      expect(prompt, contains('1. 先理解用户的真实处境和核心诉求'));
      expect(prompt, isNot(contains('## 用户已有目标')));
    });

    test('有 goals → 注入状态与标题，含合并引导', () {
      final prompt = ConversationStrategy().buildSystemPrompt(
        existingGoals: [
          _goal('三个月内找到 iOS 工作', GoalStatus.active),
          _goal('读完设计模式', GoalStatus.proposed),
        ],
      );
      expect(prompt, contains('## 用户已有目标'));
      expect(prompt, contains('- [active] 三个月内找到 iOS 工作'));
      expect(prompt, contains('- [proposed] 读完设计模式'));
      expect(prompt, contains('建议合并而非新建'));
    });
  });

  // isDuplicate 用例已随实现下沉基建：见 test/core/llm/generation/tail_dedup_test.dart
  // buildSummaryPrompt 用例已随提示词上移基建：
  // 见 test/core/llm/summary_prompt_test.dart
}
