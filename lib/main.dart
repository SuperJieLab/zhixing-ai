import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:provider/provider.dart';
import 'package:zhixing_ai/app.dart';
import 'package:zhixing_ai/core/repository/conversation_repository.dart';
import 'package:zhixing_ai/core/repository/settings_repository.dart';
import 'package:zhixing_ai/core/model_manager.dart';
import 'package:zhixing_ai/core/services/push_service.dart';
import 'package:zhixing_ai/core/services/push_socket_service.dart';

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
/// 3. 注入全局 Provider（ModelManager）
/// 4. 启动 App（runApp）
///
/// ModelManager 是单例 ChangeNotifier，使用 .value 注入。
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
    final context = navigatorKey.currentContext;
    if (context != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
              if (body.isNotEmpty) Text(body),
            ],
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  });

  // 触发推送 token 获取（异步，不阻塞启动）
  // 上面 connect() 通常已完成初始化，此处为幂等兜底（connect 跳过时仍需取 token）
  PushService().initialize();

  // 触发本地模型扫描（异步，不影响启动速度）
  ModelManager.instance.checkLocalModels();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<ModelManager>.value(value: ModelManager.instance),
      ],
      child: ZhixingApp(navigatorKey: navigatorKey),
    ),
  );
}
