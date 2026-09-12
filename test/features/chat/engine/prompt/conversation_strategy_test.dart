import 'package:test/test.dart';
import 'package:zhixing_ai/core/data/models/dashboard_models.dart';
import 'package:zhixing_ai/features/chat/engine/prompt/conversation_strategy.dart';

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

  group('isDuplicate', () {
    test('首次提问 → 不重复，记入窗口', () {
      final strategy = ConversationStrategy();
      expect(strategy.isDuplicate('怎么准备面试'), isFalse);
    });

    test('完全相同 → 重复', () {
      final strategy = ConversationStrategy();
      strategy.isDuplicate('怎么准备面试');
      expect(strategy.isDuplicate('怎么准备面试'), isTrue);
    });

    test('判重命中不推进窗口：重复后再换新问题，仍与原上一问比较', () {
      final strategy = ConversationStrategy();
      strategy.isDuplicate('怎么准备面试');
      expect(strategy.isDuplicate('怎么准备面试'), isTrue); // 重复，不追加
      expect(strategy.isDuplicate('聊聊健身计划'), isFalse); // 与"怎么准备面试"比
    });

    test('高相似（LCS > 0.8）→ 重复', () {
      final strategy = ConversationStrategy();
      strategy.isDuplicate('帮我制定一个三个月的面试复习计划');
      expect(strategy.isDuplicate('帮我制定一个三个月的面试复习计划吧'), isTrue);
    });

    test('不同问题 → 不重复', () {
      final strategy = ConversationStrategy();
      strategy.isDuplicate('怎么准备面试');
      expect(strategy.isDuplicate('今天天气不错'), isFalse);
    });

    test('首尾空白 trim 后参与比较', () {
      final strategy = ConversationStrategy();
      strategy.isDuplicate('怎么准备面试');
      expect(strategy.isDuplicate('  怎么准备面试  '), isTrue);
    });

    test('窗口容量 5：只与最近一问比较，早期问题淡出', () {
      final strategy = ConversationStrategy();
      strategy.isDuplicate('问题一');
      strategy.isDuplicate('问题二');
      strategy.isDuplicate('问题三');
      strategy.isDuplicate('问题四');
      strategy.isDuplicate('问题五');
      // 问题一已滚出窗口；与问题五完全不同 → 不重复
      expect(strategy.isDuplicate('问题一'), isFalse);
      expect(strategy.isDuplicate('问题一'), isTrue); // 已成为最近一问
    });
  });

  // buildSummaryPrompt 用例已随提示词上移基建：
  // 见 test/core/llm/summary_prompt_test.dart
}
