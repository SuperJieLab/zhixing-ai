import 'package:test/test.dart';
import 'package:zhixing_ai/core/context/summary_prompt.dart';

/// 摘要提示词（基本建默认，双端共用）单测。
///
/// 与业务侧的 `buildSystemPrompt`（人设）测试分家：摘要口径属模型能力差异。
void main() {
  group('buildSummaryPrompt', () {
    test('首次压缩：无旧摘要段，含待压缩对话与字数约束', () {
      final prompt = buildSummaryPrompt(dropped: const [
        (role: 'user', content: '我想三个月内减重 5 公斤'),
        (role: 'assistant', content: '建议从饮食和运动两方面入手'),
      ]);

      expect(prompt, isNot(contains('此前摘要')));
      expect(prompt, contains('200 字'));
      expect(prompt, contains('用户: 我想三个月内减重 5 公斤'));
      expect(prompt, contains('助手: 建议从饮食和运动两方面入手'));
      expect(prompt, contains('【待压缩对话】'));
    });

    test('递归压实：含旧摘要与合并指令', () {
      final prompt = buildSummaryPrompt(
        previousSummary: '用户在准备考试。',
        dropped: const [(role: 'user', content: '每天复习两小时')],
      );

      expect(prompt, contains('【此前摘要】'));
      expect(prompt, contains('用户在准备考试。'));
      expect(prompt, contains('合并'));
      expect(prompt, contains('用户: 每天复习两小时'));
    });

    test('空内容消息被过滤', () {
      final prompt = buildSummaryPrompt(dropped: const [
        (role: 'user', content: ''),
        (role: 'assistant', content: '正文'),
      ]);

      expect(prompt, isNot(contains('用户: ')));
      expect(prompt, contains('助手: 正文'));
    });
  });
}
