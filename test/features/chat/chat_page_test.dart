import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhixing_ai/core/data/repository/settings_repository.dart';
import 'package:zhixing_ai/core/llm/llm.dart';
import 'package:zhixing_ai/features/chat/chat_page.dart';

import '../../support/fake_llm.dart';

/// ChatPage 的 Widget 测试
///
/// 页面不再驱动加载（Task 4）：就绪态由服务（[Llm.readiness]）表达，
/// 页面据此切换 loading / 错误 / 正常视图。本文件把 [FakeLlm] 注入
/// Provider 树，走默认 provider 构造路径，分别构造
/// 「就绪 → 正常视图」与「ensure 失败 → 错误视图」两种场景。

void main() {
  // ChatPage 内部创建 ChatProvider，须先初始化 SettingsRepository
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await SettingsRepository.instance.initialize();
  });

  Widget buildTestWidget({String topic = '职业发展', FakeLlm? llm}) {
    return MaterialApp(
      home: Provider<Llm>.value(
        value: llm ?? FakeLlm(),
        child: ChatPage(topic: topic),
      ),
    );
  }

  // ============================================================
  // 测试 1：话题标题显示在 AppBar 中（所有状态都显示）
  // ============================================================
  testWidgets('ChatPage 在 AppBar 中显示话题标题', (tester) async {
    await tester.pumpWidget(buildTestWidget());
    await tester.pump(); // initState 兜底 ensureReady → ready
    expect(find.text('职业发展'), findsWidgets);
  });

  // ============================================================
  // 测试 2：就绪后展示正常对话视图（输入框 + 结束对话）
  // ============================================================
  testWidgets('ChatPage 就绪后展示正常对话视图', (tester) async {
    await tester.pumpWidget(buildTestWidget());
    await tester.pumpAndSettle();

    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('结束对话'), findsOneWidget);
  });

  // ============================================================
  // 测试 3：就绪失败展示错误视图；重试成功回到正常视图
  // ============================================================
  testWidgets('ChatPage 就绪失败展示错误视图，重试走 llm.ensureReady',
      (tester) async {
    final llm = FakeLlm()..throwOnEnsureReady = StateError('模型缺失');
    await tester.pumpWidget(buildTestWidget(llm: llm));
    await tester.pumpAndSettle();

    // 错误视图：图标 + 重试 + 返回
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.text('AI 模型加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('返回'), findsOneWidget);

    // 修复后重试成功 → 回到正常对话视图
    llm.throwOnEnsureReady = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
  });
}
