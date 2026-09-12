import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:provider/provider.dart';
import 'package:zhixing_ai/app.dart';
import 'package:zhixing_ai/core/data/repository/conversation_repository.dart';
import 'package:zhixing_ai/core/data/repository/settings_repository.dart';
import 'package:zhixing_ai/core/llm/active_model_manager.dart';
import 'package:zhixing_ai/core/llm/llm.dart';
import 'package:zhixing_ai/core/llm/llm_service.dart';
import 'package:zhixing_ai/core/platform/push_service.dart';
import 'package:zhixing_ai/core/platform/push_socket_service.dart';
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
/// 3. 注入全局 Provider（ActiveModelManager）
/// 4. 启动 App（runApp）
///
/// ActiveModelManager 是单例 ChangeNotifier，使用 .value 注入。
/// checkLocalModels() 异步扫描本地模型，不 await，完成后自动 notify。
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
  // 必须放在 Firebase 初始化之后：connect() 内部会 await PushService().getToken()，
  // 由它触发 PushService.initialize()，此时 Firebase 已就绪才能拿到真实 FCM token。
  // 也必须放在下面 PushService().initialize() 之前：那是个 fire-and-forget 调用，
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
  PushService().initialize();

  // 触发本地模型扫描（异步，不影响启动速度）
  ActiveModelManager.instance.checkLocalModels();

  // 大模型服务：composition root 全 App 唯一构造点（方案 B——唯一性来自
  // 「main() 只跑一次、只 new 一次」+ 下方 Provider 树持有，寿命与 App 相同）。
  final llm = LlmService(settings: SettingsRepository.instance);
  unawaited(llm.initialize());

  runApp(
    MultiProvider(
      providers: [
        Provider<Llm>.value(value: llm),
        ChangeNotifierProvider<ActiveModelManager>.value(value: ActiveModelManager.instance),
      ],
      child: ZhixingApp(navigatorKey: navigatorKey),
    ),
  );
}
