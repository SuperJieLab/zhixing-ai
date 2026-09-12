import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhixing_ai/core/data/models/dashboard_models.dart';
import 'package:zhixing_ai/core/data/repository/dashboard_repository.dart';
import 'package:zhixing_ai/core/data/repository/settings_repository.dart';
import 'package:zhixing_ai/features/chat/chat_page.dart';
import 'package:zhixing_ai/features/chat/providers/chat_provider.dart';

import '../../support/fake_llm.dart';

/// ChatPage 的 Widget 测试
///
/// ChatPage 创建时自动调 loadModel()（异步）。真实路径下本地模式会加载
/// llama FFI——在 macOS flutter_tester 中 dylib 可成功加载，FFI 回调在
/// FakeAsync zone 中永不完成 → pumpAndSettle 超时（「FFI 快速失败」假设
/// 已失效）。因此本文件通过 [ChatPage.providerFactory] 注入 fake `Llm`
/// 与 fake 仓库，分别构造「加载成功 → 正常视图」与「加载失败 → 错误视图」。

/// 目标仓库 fake：返回空目标（不依赖 DB）
class _OkDashboardRepo extends DashboardRepository {
  @override
  Future<List<Goal>> getActiveGoals() async => const [];
}

/// 目标仓库 fake：模拟测试环境无 DB
class _FailingDashboardRepo extends DashboardRepository {
  @override
  Future<List<Goal>> getActiveGoals() async => throw StateError('no db');
}

void main() {
  // ChatPage 内部创建 ChatProvider，构造时读取 chatCloudMode，
  // 须先初始化 SettingsRepository
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await SettingsRepository.instance.initialize();
  });

  /// 构建测试用的 ChatPage
  ///
  /// [loadOk] = true → fake Llm + 空目标仓库（加载成功，正常视图）；
  /// false → 目标仓库抛错（加载失败，错误视图）。
  Widget buildTestWidget({String topic = '职业发展', bool loadOk = true}) {
    return MaterialApp(
      home: ChatPage(
        topic: topic,
        providerFactory: ({required topic, conversation}) => ChatProvider(
          topic: topic,
          conversation: conversation,
          llm: FakeLlm(),
          dashboardRepo: loadOk ? _OkDashboardRepo() : _FailingDashboardRepo(),
        ),
      ),
    );
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
  // 测试 2：加载失败后展示错误视图（fake 仓库抛错 → modelError）
  // ============================================================
  testWidgets('ChatPage 模型加载失败后展示错误视图', (tester) async {
    await tester.pumpWidget(buildTestWidget(loadOk: false));

    // 等待 loadModel() 异步完成（fake 全部同步返回，pumpAndSettle 即可）
    await tester.pumpAndSettle();

    // 模型加载失败后显示错误图标 + 重试 + 返回按钮
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.text('AI 模型加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('返回'), findsOneWidget);
  });

  // ============================================================
  // 测试 3：加载成功后进入正常对话视图（输入框 + 结束对话）
  // ============================================================
  testWidgets('ChatPage 加载成功后展示正常对话视图', (tester) async {
    await tester.pumpWidget(buildTestWidget());
    await tester.pumpAndSettle();

    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('结束对话'), findsOneWidget);
  });
}
