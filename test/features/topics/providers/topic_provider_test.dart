import 'package:flutter_test/flutter_test.dart';
import 'package:socratic_ai/features/topics/providers/topic_provider.dart';

/// TopicProvider 的单元测试
///
/// ## 什么是单元测试？
/// 单元测试不运行 App、不渲染 UI，只在内存里创建对象、
/// 调用方法、验证结果。速度快、可重复、不依赖设备。
///
/// ## 测试框架
/// Flutter 内置的 flutter_test 包提供了：
/// - test() — 定义一个测试用例
/// - group() — 把相关测试分组（方便组织和阅读）
/// - expect() — 断言：判断「实际值」是否等于「期望值」
/// - setUp() — 每个测试开始前自动执行的准备代码
///
/// ## 运行方式
/// ```bash
/// flutter test test/features/topics/providers/topic_provider_test.dart
/// ```
void main() {
  // group() 把 3 个测试用例归为一组，报告时会显示在一起
  group('TopicProvider', () {
    late TopicProvider provider;

    // setUp() 会在【每个】test 开始前自动执行，
    // 保证每个测试用例都是从一个干净的新建对象开始，
    // 不会受前一个测试的残留状态影响
    setUp(() {
      provider = TopicProvider();
    });

    // ============================================================
    // 测试 1：初始状态
    // ============================================================
    test('初始状态下，selectedTopic 应为 null，customTopic 应为空字符串', () {
      // isNull — 判断值是否为 null
      expect(provider.selectedTopic, isNull);

      // isEmpty — 判断字符串是否为空（''）
      expect(provider.customTopic, isEmpty);
    });

    // ============================================================
    // 测试 2：选择预设话题
    // ============================================================
    test('调用 selectTopic 后，selectedTopic 应更新为传入的值', () {
      // 执行：选择「职业发展」这个话题
      provider.selectTopic('职业发展');

      // 断言：selectedTopic 应该变成 '职业发展'
      expect(provider.selectedTopic, '职业发展');
    });

    // ============================================================
    // 测试 3：自定义输入话题
    // ============================================================
    test('调用 setCustomTopic 后，customTopic 应更新为传入的值', () {
      // 执行：用户输入了「如何处理焦虑」
      provider.setCustomTopic('如何处理焦虑');

      // 断言：customTopic 应该变成用户输入的文本
      expect(provider.customTopic, '如何处理焦虑');
    });

    // ============================================================
    // 测试 4：选预设话题后，自定义话题应被清空
    // ============================================================
    test('选择预设话题后，自定义话题应被清空', () {
      // 先输入自定义话题
      provider.setCustomTopic('如何处理焦虑');

      // 再选择预设话题 —— 这应该自动清空自定义话题
      provider.selectTopic('职业发展');

      // 断言：自定义话题被清空了
      expect(provider.customTopic, isEmpty);
    });

    // ============================================================
    // 测试 5：自定义输入后，预设话题应被清空
    // ============================================================
    test('自定义输入话题后，预设话题应被清空', () {
      // 先选一个预设话题
      provider.selectTopic('职业发展');

      // 再输入自定义话题 —— 这应该自动取消预设选择
      provider.setCustomTopic('如何克服拖延');

      // 断言：预设话题被清空
      expect(provider.selectedTopic, isNull);
    });
  });
}
