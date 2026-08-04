import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:provider/provider.dart';
import 'package:zhixing_ai/app.dart';
import 'package:zhixing_ai/core/repository/conversation_repository.dart';
import 'package:zhixing_ai/core/repository/settings_repository.dart';
import 'package:zhixing_ai/core/model_manager.dart';
import 'package:zhixing_ai/core/services/push_service.dart';

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

  // 触发推送 token 获取（异步，不阻塞启动）
  PushService().initialize();

  // 触发本地模型扫描（异步，不影响启动速度）
  ModelManager.instance.checkLocalModels();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<ModelManager>.value(value: ModelManager.instance),
      ],
      child: const ZhixingApp(),
    ),
  );
}
