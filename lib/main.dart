import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:socratic_ai/app.dart';
import 'package:socratic_ai/core/repository/conversation_repository.dart';
import 'package:socratic_ai/features/topics/providers/topic_provider.dart';

/// 应用入口
///
/// main() 中完成：
/// 1. 初始化 sqflite（ConversationRepository）
/// 2. 注入全局 Provider（只有 TopicProvider）
/// 3. 启动 App（runApp）
///
/// ConversationService 不再通过 Provider 注入——调用方直接使用其实例。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化本地数据库
  await ConversationRepository.initialize();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => TopicProvider()),
      ],
      child: const SocraticApp(),
    ),
  );
}
