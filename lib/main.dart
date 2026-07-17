import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:zhixing_ai/app.dart';
import 'package:zhixing_ai/core/repository/conversation_repository.dart';
import 'package:zhixing_ai/core/model_manager.dart';

/// 应用入口
///
/// main() 中完成：
/// 1. 初始化 sqflite（ConversationRepository）
/// 2. 注入全局 Provider（ModelManager）
/// 3. 启动 App（runApp）
///
/// ModelManager 是单例 ChangeNotifier，使用 .value 注入。
/// checkLocalModels() 异步扫描本地模型，不 await，完成后自动 notify。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化本地数据库
  await ConversationRepository.initialize();

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
