import 'package:test/test.dart';
import 'package:zhixing_ai/core/llm/generation/tail_dedup.dart';

/// 尾部问题去重（原 `conversation_strategy_test` 的 `isDuplicate` 组随实现下沉迁移）。
void main() {
  group('TailDeduplicator.isDuplicate', () {
    test('首次提问 → 不重复，记入窗口', () {
      expect(TailDeduplicator().isDuplicate('怎么准备面试'), isFalse);
    });

    test('完全相同 → 重复', () {
      final dedup = TailDeduplicator();
      dedup.isDuplicate('怎么准备面试');
      expect(dedup.isDuplicate('怎么准备面试'), isTrue);
    });

    test('判重命中不推进窗口：重复后再换新问题，仍与原上一问比较', () {
      final dedup = TailDeduplicator();
      dedup.isDuplicate('怎么准备面试');
      expect(dedup.isDuplicate('怎么准备面试'), isTrue); // 重复，不追加
      expect(dedup.isDuplicate('聊聊健身计划'), isFalse); // 与"怎么准备面试"比
    });

    test('高相似（LCS > 0.8）→ 重复', () {
      final dedup = TailDeduplicator();
      dedup.isDuplicate('帮我制定一个三个月的面试复习计划');
      expect(dedup.isDuplicate('帮我制定一个三个月的面试复习计划吧'), isTrue);
    });

    test('不同问题 → 不重复', () {
      final dedup = TailDeduplicator();
      dedup.isDuplicate('怎么准备面试');
      expect(dedup.isDuplicate('今天天气不错'), isFalse);
    });

    test('首尾空白 trim 后参与比较', () {
      final dedup = TailDeduplicator();
      dedup.isDuplicate('怎么准备面试');
      expect(dedup.isDuplicate('  怎么准备面试  '), isTrue);
    });

    test('窗口容量 5：只与最近一问比较，早期问题淡出', () {
      final dedup = TailDeduplicator();
      dedup.isDuplicate('问题一');
      dedup.isDuplicate('问题二');
      dedup.isDuplicate('问题三');
      dedup.isDuplicate('问题四');
      dedup.isDuplicate('问题五');
      // 问题一已滚出窗口；与问题五完全不同 → 不重复
      expect(dedup.isDuplicate('问题一'), isFalse);
      expect(dedup.isDuplicate('问题一'), isTrue); // 已成为最近一问
    });

    test('reset 清空窗口（交付实现与 App 同寿命，窗口不得跨会话泄漏）', () {
      final dedup = TailDeduplicator();
      dedup.isDuplicate('怎么准备面试');
      dedup.reset();
      // 窗口已空 → 与「上一问」无从比较，按首次提问处理
      expect(dedup.isDuplicate('怎么准备面试'), isFalse);
    });
  });
}
