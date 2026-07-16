import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:socratic_ai/core/engine/model_manager.dart';
import 'package:socratic_ai/features/topics/topic_selection_page.dart';

/// TopicSelectionPage 的 Widget 测试
///
/// 测试重点：
/// 1. 5 个预设话题卡片是否全部渲染
/// 2. 自定义输入框是否存在
void main() {
  testWidgets('TopicSelectionPage 显示全部 5 个预设话题', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<ModelManager>.value(
        value: ModelManager.instance,
        child: const MaterialApp(home: TopicSelectionPage()),
      ),
    );

    expect(find.text('职业发展'), findsOneWidget);
    expect(find.text('两难决策'), findsOneWidget);
    expect(find.text('自我探索'), findsOneWidget);
    expect(find.text('工作难题'), findsOneWidget);
    expect(find.text('人际关系'), findsOneWidget);
  });

  testWidgets('TopicSelectionPage 包含自定义话题输入框', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<ModelManager>.value(
        value: ModelManager.instance,
        child: const MaterialApp(home: TopicSelectionPage()),
      ),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pump();

    expect(find.byType(TextField), findsOneWidget);
  });
}
