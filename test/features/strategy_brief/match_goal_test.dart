import 'package:flutter_test/flutter_test.dart';
import 'package:zhixing_ai/core/data/models/dashboard_models.dart';
import 'package:zhixing_ai/features/strategy_brief/providers/strategy_brief_provider.dart';

/// [matchGoal] 纯函数回归（修复：重名目标时 firstWhere 恒命中第一条的误配）。
void main() {
  Goal goal({int? id, required String title}) => Goal(
        id: id,
        title: title,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

  test('goalId 优先：重名目标按 id 精确命中', () {
    final goals = [
      goal(id: 1, title: '减脂'),
      goal(id: 2, title: '减脂'),
    ];

    final matched = matchGoal(goals, goalId: 2, goalTitle: '减脂');

    expect(matched?.id, 2);
  });

  test('goalId 未命中：回退 title 匹配（兼容旧缓存/模型未回传 id）', () {
    final goals = [goal(id: 7, title: '学英语')];

    final matched = matchGoal(goals, goalId: 99, goalTitle: '学英语');

    expect(matched?.id, 7);
  });

  test('无 goalId：按 title 匹配', () {
    final goals = [goal(id: 3, title: '读书'), goal(id: 4, title: '跑步')];

    expect(matchGoal(goals, goalTitle: '跑步')?.id, 4);
  });

  test('id 与 title 均未命中：返回 null（不再伪造空 Goal）', () {
    final goals = [goal(id: 1, title: '减脂')];

    expect(matchGoal(goals, goalId: 9, goalTitle: '不存在的目标'), isNull);
    expect(matchGoal(goals, goalId: null, goalTitle: '不存在的目标'), isNull);
    expect(matchGoal(goals), isNull);
  });
}
