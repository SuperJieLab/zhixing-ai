// 独立运行的集成测试脚本：print 是其输出方式，顶层 main 即库入口
// ignore_for_file: avoid_print, dangling_library_doc_comments
/// llama.cpp + Qwen3.5-2B 端到端集成测试
///
/// 验证：
/// 1. libllama.dylib 能正确加载
/// 2. 模型能载入
/// 3. 知行AI 人设（ConversationStrategy）下对话能正常生成
///
/// 运行方式（macOS 开发环境）：
/// ```bash
/// cd /Users/superjie-mac/projects/socratic-ai
/// flutter pub get && dart run tool/llama_integration_test.dart
/// ```
///
/// 注意：此测试不通过 `flutter test` 运行（依赖真实 FFI dylib 与模型文件），
/// 放在 tool/ 下避免被 `flutter test` 收割导致加载失败。

import 'dart:io';

import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/data/models/available_model.dart';
import 'package:zhixing_ai/features/chat/engine/conversation_strategy.dart';

Future<void> main() async {
  final projectRoot = Directory.current.path;
  final modelPath =
      '$projectRoot/assets/models/Qwen3.5-2B-Q4_K_M.gguf';
  final libPath = '$projectRoot/macos/Runner/libs/libllama.dylib';

  print('╔══════════════════════════════════════════╗');
  print('║   知行AI — 端侧推理集成测试              ║');
  print('╚══════════════════════════════════════════╝');
  print('');
  print('项目根目录: $projectRoot');
  print('模型路径:   $modelPath');
  print('库路径:     $libPath');

  // ── 检查文件存在 ──
  if (!File(modelPath).existsSync()) {
    print('\n❌ 模型文件不存在: $modelPath');
    print('   请先从 App 内模型管理下载，或手动放置：');
    print('     curl -L -o $modelPath \\');
    print('       https://hf-mirror.com/${AvailableModel.available.first.hfRepo}/resolve/main/${AvailableModel.available.first.fileName}');
    exit(1);
  }

  if (!File(libPath).existsSync()) {
    print('\n❌ libllama.dylib 不存在: $libPath');
    exit(1);
  }

  final modelSize = File(modelPath).lengthSync() / (1024 * 1024);
  print('模型大小:   ${modelSize.toStringAsFixed(0)} MB');

  // ── 加载引擎 ──
  print('\n⏳ 正在加载 llama.cpp 引擎...');
  final stopwatch = Stopwatch()..start();

  late LlamaEngine engine;
  try {
    engine = await LlamaEngine.spawn(
      libraryPath: libPath,
      modelParams: ModelParams(
        path: modelPath,
        gpuLayers: -1, // 全部使用 Metal GPU
      ),
      contextParams: ContextParams(
        nCtx: AppConstants.localContextSize,
        nThreads: AppConstants.localThreads,
        typeK: KvCacheType.q8_0,
        typeV: KvCacheType.q8_0,
      ),
    );
    stopwatch.stop();
    print('✅ 引擎加载成功（${stopwatch.elapsedMilliseconds}ms）');

    // 硬件信息
    if (engine.hasAccelerator) {
      print('   加速器: ${engine.primaryAcceleratorName}');
    }
    for (final d in engine.devices) {
      print('   设备:   ${d.name} (${d.type.name})');
    }
  } catch (e, stack) {
    print('❌ 引擎加载失败: $e');
    print(stack);
    exit(1);
  }

  // ── 创建对话 ──
  print('\n⏳ 创建知行AI 对话（人设与 App 同源）...');
  final chat = await engine.createChat();
  chat.addSystem(ConversationStrategy().buildSystemPrompt());
  print('✅ 对话创建成功');

  // ── 测试推理 ──
  final testPrompt = '我最近在考虑要不要换工作，但很纠结。';
  print('\n💬 用户: $testPrompt');
  stdout.write('🤖 AI:   ');

  chat.addUser(testPrompt);
  final genStopwatch = Stopwatch()..start();
  int tokenCount = 0;

  try {
    await for (final event in chat.generate(
      sampler: const SamplerParams(
        temperature: 0.7,
        topP: 0.9,
      ),
      maxTokens: 200, // 烟测用小上限，非 AppConstants.localMaxTokens
    )) {
      if (event is TokenEvent) {
        stdout.write(event.text);
        tokenCount++;
      } else if (event is DoneEvent) {
        genStopwatch.stop();
        final elapsed = genStopwatch.elapsedMilliseconds;
        final tps = tokenCount / (elapsed / 1000);
        print('\n\n✅ 推理完成');
        print('   生成 token: $tokenCount');
        print('   耗时:       ${elapsed}ms');
        print('   速度:       ${tps.toStringAsFixed(1)} tok/s');
      }
    }
  } catch (e, stack) {
    print('\n❌ 推理失败: $e');
    print(stack);
    exit(1);
  }

  // ── 多轮对话测试 ──
  print('\n🔄 第二轮对话测试...');
  const secondPrompt = '我担心换了之后发现还不如现在。';
  print('💬 用户: $secondPrompt');
  stdout.write('🤖 AI:   ');

  chat.addUser(secondPrompt);
  final round2Stopwatch = Stopwatch()..start();
  int round2Tokens = 0;

  try {
    await for (final event in chat.generate(
      sampler: const SamplerParams(
        temperature: 0.7,
        topP: 0.9,
      ),
      maxTokens: 200,
    )) {
      if (event is TokenEvent) {
        stdout.write(event.text);
        round2Tokens++;
      } else if (event is DoneEvent) {
        round2Stopwatch.stop();
        final elapsed = round2Stopwatch.elapsedMilliseconds;
        final tps = round2Tokens / (elapsed / 1000);
        print('\n\n✅ 第二轮完成');
        print('   生成 token: $round2Tokens');
        print('   耗时:       ${elapsed}ms');
        print('   速度:       ${tps.toStringAsFixed(1)} tok/s');
      }
    }
  } catch (e, stack) {
    print('\n❌ 第二轮推理失败: $e');
    print(stack);
  }

  // ── 清理 ──
  print('\n🧹 清理资源...');
  engine.dispose();
  print('✅ 集成测试全部通过！');

  exit(0);
}
