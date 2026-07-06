import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:socratic_ai/core/constants.dart';
import 'package:socratic_ai/core/engine/insight_service.dart';
import 'package:socratic_ai/core/engine/llama_service.dart';
import 'package:socratic_ai/core/engine/socratic_prompter.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/chat/providers/chat_provider.dart';
import 'package:socratic_ai/features/chat/widgets/chat_bubble.dart';
import 'package:socratic_ai/features/chat/widgets/chat_input.dart';
import 'package:socratic_ai/features/insights/insights_page.dart';

/// 对话页面
///
/// 用户与 AI 进行苏格拉底式深度对话的页面。
/// 进入页面时自动加载 Qwen 模型（约 13 秒），加载期间显示进度。
/// 模型加载失败不影响使用——自动回退到 Mock 回复。
///
/// ## 架构
/// ChatPage 在 initState 中创建 LlamaService + SocraticPrompter，
/// 注入 ChatProvider。ChatProvider 只依赖 DialogueEngine 接口。
class ChatPage extends StatefulWidget {
  final String topic;

  const ChatPage({super.key, required this.topic});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  /// 模型加载进度：null = 未开始 / true = 加载中 / false = 完成
  bool? _modelLoading;

  /// 对话引擎（注入到 ChatProvider）
  SocraticPrompter? _engine;

  /// 消息列表的滚动控制器
  final ScrollController _scrollController = ScrollController();

  /// 上一次渲染时的消息数量，变化时触发自动滚动
  int _lastMessageCount = -1;

  @override
  void initState() {
    super.initState();
    _initEngine();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _engine?.dispose();
    super.dispose();
  }

  /// 初始化对话引擎（后台加载模型，不阻塞 UI）
  Future<void> _initEngine() async {
    setState(() => _modelLoading = true);

    try {
      // ── dylib 路径：从 App Bundle 内部加载 ──
      final executable = File(Platform.resolvedExecutable);
      final bundleContents = executable.parent.parent; // MacOS → Contents
      final libPath = '${bundleContents.path}/Frameworks/libllama.dylib';

      // ── 模型路径：开发阶段用绝对路径（debug build 无法反向解析到项目根目录）
      // Day 9 模型自动下载到沙盒后将替换此逻辑
      final modelPath = AppConstants.macosDevModelAbsolutePath;

      final llm = LlamaService();
      await llm.loadModel(
        modelPath: modelPath,
        libraryPath: libPath,
        contextSize: AppConstants.modelContextSize,
        gpuLayers: AppConstants.modelGpuLayers,
        threads: AppConstants.modelThreads,
      );

      final engine = SocraticPrompter(llm);
      await engine.initialize();
      _engine = engine;
    } catch (e) {
      debugPrint('[ChatPage] 模型加载失败，将使用 Mock 回复: $e');
    } finally {
      if (mounted) setState(() => _modelLoading = false);
    }
  }

  Future<void> _endConversation(BuildContext context, ChatProvider chatProvider) async {
    // 显示 loading 弹窗
    if (!context.mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: Center(
          child: Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: AppTheme.primary),
                  SizedBox(height: 16),
                  Text(
                    '正在生成洞察总结...',
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    // 调用 InsightService 生成洞察
    InsightResult insight;
    try {
      final service = InsightService(_engine!.llmService);
      insight = await service.analyze(
        widget.topic,
        chatProvider.messages,
      );
    } catch (e) {
      debugPrint('[ChatPage] 洞察生成失败: $e');
      insight = const InsightResult(
        coreInsights: ['对话分析完成'],
        underlyingValues: [],
        contradictionsFound: [],
      );
    }

    // 关闭 loading 弹窗，跳转到洞察页
    if (!context.mounted) return;
    Navigator.pop(context); // 关闭 loading
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => InsightsPage(
          insight: insight,
          topic: widget.topic,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 引擎加载中 → 显示全屏 loading，不创建 ChatProvider
    if (_modelLoading == true) {
      return Scaffold(
        appBar: AppBar(
          backgroundColor: AppTheme.background,
          title: Text(widget.topic),
        ),
        body: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: AppTheme.primary),
              SizedBox(height: 16),
              Text(
                '正在加载 AI 模型（约 15 秒）...',
                style: TextStyle(color: AppTheme.textSecondary),
              ),
            ],
          ),
        ),
      );
    }

    // 引擎就绪（或加载失败 → Mock 回退）→ 创建 ChatProvider
    return ChangeNotifierProvider(
      create: (_) => ChatProvider(topic: widget.topic, engine: _engine),
      child: Consumer<ChatProvider>(
        builder: (context, chatProvider, _) {
          // 消息数量变化时，下一帧自动滚动到底部
          if (chatProvider.messages.length != _lastMessageCount) {
            _lastMessageCount = chatProvider.messages.length;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_scrollController.hasClients) {
                _scrollController.animateTo(
                  _scrollController.position.maxScrollExtent,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                );
              }
            });
          }

          return Scaffold(
            appBar: AppBar(
              backgroundColor: AppTheme.background,
              surfaceTintColor: Colors.transparent,
              scrolledUnderElevation: 0,
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.topic, style: const TextStyle(fontSize: 16)),
                  Text(
                    '第 ${chatProvider.round} 轮',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton.icon(
                  onPressed: () => _endConversation(context, chatProvider),
                  icon: const Icon(
                    Icons.stop_circle_outlined,
                    color: AppTheme.secondary,
                    size: 18,
                  ),
                  label: const Text(
                    '结束对话',
                    style: TextStyle(color: AppTheme.secondary, fontSize: 13),
                  ),
                ),
              ],
            ),
            body: Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    itemCount: chatProvider.messages.length,
                    itemBuilder: (context, index) {
                      return ChatBubble(
                        message: chatProvider.messages[index],
                      );
                    },
                  ),
                ),
                if (chatProvider.isThinking)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Row(
                      children: [
                        SizedBox(width: 48),
                        _ThinkingIndicator(),
                      ],
                    ),
                  ),
                ChatInput(
                  onSend: (message) {
                    chatProvider.sendMessage(message);
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// AI「思考中」动画指示器
class _ThinkingIndicator extends StatefulWidget {
  const _ThinkingIndicator();

  @override
  State<_ThinkingIndicator> createState() => _ThinkingIndicatorState();
}

class _ThinkingIndicatorState extends State<_ThinkingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildDot(0),
            const SizedBox(width: 4),
            _buildDot(1),
            const SizedBox(width: 4),
            _buildDot(2),
            const SizedBox(width: 8),
            const Text(
              '正在思考...',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
            ),
          ],
        );
      },
    );
  }

  Widget _buildDot(int index) {
    final delay = index * 0.2;
    final progress = (_controller.value - delay).clamp(0.0, 1.0);
    final scale =
        0.5 + 0.5 * (progress < 0.5 ? progress * 2 : 2 - progress * 2);

    return Transform.scale(
      scale: scale,
      child: Container(
        width: 6,
        height: 6,
        decoration: const BoxDecoration(
          color: AppTheme.primary,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
