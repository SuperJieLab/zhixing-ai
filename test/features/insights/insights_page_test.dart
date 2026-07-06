import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/features/insights/insights_page.dart';

void main() {
  group('InsightsPage', () {
    testWidgets('展示核心洞察、价值观标签和矛盾', (tester) async {
      final insight = InsightResult(
        coreInsights: ['你重视安全感胜过冒险'],
        underlyingValues: ['安全感', '稳定性'],
        contradictionsFound: ['你说想要自由，但又害怕不确定性'],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: InsightsPage(insight: insight, topic: '职业发展'),
        ),
      );

      // 等待 stagger 动画完成
      await tester.pumpAndSettle();

      expect(find.text('「职业发展」的对话洞察'), findsOneWidget);
      expect(find.text('你重视安全感胜过冒险'), findsOneWidget);
      expect(find.text('安全感'), findsOneWidget);
      expect(find.text('稳定性'), findsOneWidget);
      expect(find.text('你说想要自由，但又害怕不确定性'), findsOneWidget);
    });

    testWidgets('洞察为空时显示回退提示', (tester) async {
      const insight = InsightResult(
        coreInsights: [],
        underlyingValues: [],
        contradictionsFound: [],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: InsightsPage(insight: insight, topic: '测试'),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('对话已结束'), findsOneWidget);
      expect(find.text('AI 模型未加载，无法生成洞察总结。'), findsOneWidget);
    });

    testWidgets('开始新对话按钮可点击', (tester) async {
      final insight = InsightResult(
        coreInsights: ['测试洞察'],
        underlyingValues: [],
        contradictionsFound: [],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: InsightsPage(insight: insight, topic: '测试'),
        ),
      );

      await tester.pumpAndSettle();

      final newChatButton = find.text('开始新对话');
      expect(newChatButton, findsOneWidget);
      // 按钮存在且未被 disabled
      final button = tester.widget<FilledButton>(find.ancestor(
        of: newChatButton,
        matching: find.byType(FilledButton),
      ));
      expect(button.onPressed, isNotNull);
    });

    testWidgets('查看思维图谱按钮暂时不可用', (tester) async {
      final insight = InsightResult(
        coreInsights: ['测试洞察'],
        underlyingValues: [],
        contradictionsFound: [],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: InsightsPage(insight: insight, topic: '测试'),
        ),
      );

      await tester.pumpAndSettle();

      final graphButton = find.text('查看思维图谱');
      expect(graphButton, findsOneWidget);
      // 按钮存在但被 disabled（Day 7 才启用）
      final button = tester.widget<OutlinedButton>(find.ancestor(
        of: graphButton,
        matching: find.byType(OutlinedButton),
      ));
      expect(button.onPressed, isNull);
    });
  });
}
