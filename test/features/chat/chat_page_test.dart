import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhixing_ai/core/data/repository/settings_repository.dart';
import 'package:zhixing_ai/core/model_gateway.dart';
import 'package:zhixing_ai/features/chat/chat_page.dart';
import 'package:zhixing_ai/features/strategy_brief/strategy_brief_page.dart';

import '../../support/fake_llm.dart';

/// ChatPage 的 Widget 测试
///
/// 页面不再驱动加载（Task 4）：就绪态由服务（[LlmReadiness]，经
/// ModelGateway 透传）表达，页面据此切换 loading / 错误 / 正常视图。
/// 本文件把 [FakeGateway] 注入 Provider 树，走默认 provider 构造路径，
/// 分别构造「就绪 → 正常视图」与「ensure 失败 → 错误视图」两种场景。

void main() {
  // ChatPage 内部创建 ChatProvider，须先初始化 SettingsRepository
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await SettingsRepository.instance.initialize();
  });

  /// 测试树与生产一致：`MultiProvider` 包在 `MaterialApp` **外层**——
  /// 这样 `Navigator.pushReplacement` 推出的新路由（如分析页）仍是它的
  /// 后代，才能读到 ModelGateway。若把 Provider 放进 `home` 内部，新路由
  /// 会变成它的兄弟，读取必然抛 ProviderNotFound（真实 bug 的测试镜像）。
  Widget buildTestWidget({String topic = '职业发展', FakeLlm? llm}) {
    return Provider<ModelGateway>.value(
      value: FakeGateway(llm: llm ?? FakeLlm()),
      child: MaterialApp(
        home: ChatPage(topic: topic),
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
  testWidgets('ChatPage 就绪失败展示错误视图，重试走 gateway.ensureReady',
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

  // ============================================================
  // 测试 4：结束对话 → 跳转分析页
  //
  // 回归用例：`_endConversation` 曾在 State.context 上
  // `read<ChatProvider>()`——而该 Provider 由 ChatPage.build 创建、位于
  // 本元素**后代**，查找必抛 ProviderNotFoundException（真机点击即崩）。
  // ============================================================
  testWidgets('点击「结束对话」跳转 StrategyBriefPage，不抛 Provider 异常',
      (tester) async {
    await tester.pumpWidget(buildTestWidget());
    await tester.pumpAndSettle();
    expect(find.text('结束对话'), findsOneWidget);

    await tester.tap(find.text('结束对话'));
    // 前两帧：处理点击（pushReplacement）+ 路由转场。不用 pumpAndSettle：
    // 分析页会异步读 DB（测试环境 sqflite 不可用）并转入错误态，用固定
    // 帧数推进即可，避免等待settle带来的不确定性。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(find.byType(StrategyBriefPage), findsOneWidget);
  });
}
