import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:provider/provider.dart';
import 'package:zhixing_ai/app.dart';
import 'package:zhixing_ai/core/data/repository/conversation_repository.dart';
import 'package:zhixing_ai/core/data/repository/settings_repository.dart';
import 'package:zhixing_ai/core/llm/engine/active_model_manager.dart';
import 'package:zhixing_ai/core/llm/llm_service.dart';
import 'package:zhixing_ai/core/model_gateway.dart';
import 'package:zhixing_ai/core/platform/push_service.dart';
import 'package:zhixing_ai/core/platform/push_socket_service.dart';
import 'package:zhixing_ai/core/platform/sync_service.dart';
import 'package:zhixing_ai/core/ui/in_app_banner.dart';

/// 全局 Navigator key
///
/// 传给 [ZhixingApp] → MaterialApp，使非 Widget 层（如 WS 推送回调）
/// 也能拿到 BuildContext 弹应用内横幅。
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// 应用入口
///
/// main() 中完成：
/// 1. 初始化 sqflite（ConversationRepository）
/// 2. 初始化 Firebase（未配置时 catch 忽略，不影响 App 运行）
/// 3. 组合根装配：构造共享实例（LlmService / ModelGateway / ActiveModelManager /
///    SyncService）并注入 Provider 树
/// 4. 启动 App（runApp）
///
/// ActiveModelManager 非单例，在此构造一次经 Provider 树下发；
/// checkLocalModels() 异步扫描本地模型，不 await，完成后自动 notify
/// （模型就绪即经 activeModelPath 通知 LlmService 加载引擎）。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化本地数据库
  await ConversationRepository.initialize();

  // 初始化用户设置（SharedPreferences 预取）
  await SettingsRepository.instance.initialize();

  // 初始化 Firebase（未配置时 catch 异常，不影响 App 运行）
  try {
    await Firebase.initializeApp();
  } catch (e) {
    // Firebase 未配置时忽略
  }

  // 建立站内推送 WS 长连接（异步，不阻塞启动）
  //
  // 必须放在 Firebase 初始化之后：connect() 内部会 await PushService.instance.getToken()，
  // 由它触发 PushService.initialize()，此时 Firebase 已就绪才能拿到真实 FCM token。
  // 也必须放在下面 PushService.instance.initialize() 之前：那是个 fire-and-forget 调用，
  // 会先把 _initialized 置 true，导致 getToken() 直接返回尚未就绪的 null，
  // 而 connect() 拿到 null token 会静默放弃且不重连。
  unawaited(PushSocketService.instance.connect());
  PushSocketService.instance.addHandler((title, body) {
    final overlay = navigatorKey.currentState?.overlay;
    if (overlay != null) {
      InAppBanner.show(overlay, title: title, body: body);
    }
  });

  // 触发推送 token 获取（异步，不阻塞启动）
  // 上面 connect() 通常已完成初始化，此处为幂等兜底（connect 跳过时仍需取 token）
  PushService.instance.initialize();

  // ─── 组合根（composition root）：共享实例只在这里构造一次 ───
  //
  // 唯一性来源是「main() 只跑一次 + 下面 Provider 树持有」，而非 static 字段：
  // 需要可替换的实例走 Provider / 构造注入（ModelGateway / ActiveModelManager /
  // SyncService），确实进程级唯一的基础设施保持单例（SettingsRepository /
  // PushService / PushSocketService / LlamaService）。

  final settings = SettingsRepository.instance;

  // 活跃模型状态：非单例；UI 经 Provider 树 watch 消费，
  // 其路径源（activeModelPath）注入给 LlmService（取代原先的全局常量）。
  final modelManager = ActiveModelManager();
  unawaited(modelManager.checkLocalModels());

  final llm = LlmService(
    settings: settings,
    activeModelPath: modelManager.activeModelPath,
  );
  unawaited(llm.initialize());

  // 业务唯一门面（v2 分层）：组合 llm 基建 + 模式源 + 生产交付工厂。
  final gateway = ModelGateway(
    llm: llm,
    modeSource: llm.mode,
    deliveryFactory: llm.deliveryFor,
  );

  // 数据同步：无状态副作用服务，业务侧经 Provider 树取（DashboardProvider 消费）。
  final syncService = SyncService(settings: settings);

  runApp(
    MultiProvider(
      providers: [
        Provider<ModelGateway>.value(value: gateway),
        Provider<SyncService>.value(value: syncService),
        ChangeNotifierProvider<ActiveModelManager>.value(value: modelManager),
      ],
      child: ZhixingApp(navigatorKey: navigatorKey),
    ),
  );
}
