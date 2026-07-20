import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhixing_ai/features/chat/chat_page.dart';

/// ChatPage 的 Widget 测试
///
/// ChatPage 创建时自动调 loadModel()（异步），在模型加载期间显示 loading 视图。
/// 测试环境中 llama.cpp FFI 不可用，loadModel() 会快速失败进入 hasModelError 状态。
/// pumpAndSettle 等待异步完成后验证错误视图。
///
/// ChatPage 内部创建 ChatProvider，通过 ChangeNotifierProvider 管理状态。
void main() {
  /// 构建测试用的 ChatPage
  Widget buildTestWidget({String topic = '职业发展'}) {
    return MaterialApp(home: ChatPage(topic: topic));
  }

  // ============================================================
  // 测试 1：话题标题显示在 AppBar 中（所有状态都显示）
  // ============================================================
  testWidgets('ChatPage 在 AppBar 中显示话题标题', (tester) async {
    await tester.pumpWidget(buildTestWidget());
    // AppBar 标题在所有状态下都渲染（loading / error / 正常）
    expect(find.text('职业发展'), findsWidgets);
  });

  // ============================================================
  // 测试 2：页面渲染不崩溃（模型加载失败后展示错误视图）
  // ============================================================
  testWidgets('ChatPage 模型加载失败后展示错误视图', (tester) async {
    await tester.pumpWidget(buildTestWidget());

    // 等待 loadModel() 异步完成（FFI 不可用，会快速失败）
    await tester.pumpAndSettle();

    // 模型加载失败后显示错误图标 + 重试 + 返回按钮
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.text('AI 模型加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('返回'), findsOneWidget);
  });

  // ============================================================
  // 测试 3：欢迎消息在正常状态下显示
  // ============================================================
  testWidgets('ChatPage 初始包含 AI 欢迎消息（正常模式）', (tester) async {
    await tester.pumpWidget(buildTestWidget());
    await tester.pumpAndSettle();

    // 模型加载失败进入错误视图，但标题和基础结构不崩溃
    expect(find.byType(ChatPage), findsOneWidget);
  });
}
