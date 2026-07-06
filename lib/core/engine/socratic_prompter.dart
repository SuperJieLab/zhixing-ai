import 'package:flutter/foundation.dart';

import 'dialogue_engine.dart';
import 'llama_service.dart';

/// 追问维度轮换表（5 个维度，按顺序循环）
const _dimensions = ['原因', '假设', '影响', '对比', '行动'];

/// 苏格拉底式教练的系统提示词（few-shot 版）
///
/// 追问维度由 Dart 端硬编码轮换，去重也在 Dart 端完成。
/// 开场白通过 addAssistant 注入 chat 历史。
///
/// 针对 Qwen3.5-2B：明确指示不输出思考过程。
const _socraticSystemPrompt = '''
你是一位苏格拉底式教练。你的任务是只通过提问帮助用户深入思考，不给建议、不做评判。

**重要：直接输出追问问题，不要输出思考过程、不要输出推理步骤。**

用户消息中包含追问维度标记，你只需要基于标记的维度追问一个问题：

## 示例
用户："追问维度：【原因】\\n我觉得换工作是因为现在太累了"
你："累的背后是什么——是工作内容本身，还是节奏问题，还是成长空间不够？"

用户："追问维度：【行动】\\n我想开始学一门新技术"
你："具体从哪一步开始？每天能拿出多少时间来？"

## 追问维度
- 【原因】→ 追问背后的动机、原因
- 【假设】→ 追问前提条件，换个角度思考
- 【影响】→ 追问带来的后果、长期影响
- 【对比】→ 追问差异、矛盾
- 【行动】→ 追问具体计划、第一步

## 规则
1. 先简要回应用户的观点，再提一个开放性问题
2. 问题控制在 150 字以内，用中文
3. 不要给建议，不要一次问多个问题
4. 不要重复之前问过的内容
5. 不要输出思考过程：不输出 think 标签，不输出推理步骤''';

/// 苏格拉底式追问引擎
///
/// 实现 [DialogueEngine] 接口，组合 [LlamaService] 提供完整对话能力：
/// - Prompt 模板构建
/// - 追问维度轮换
/// - 去重检测
/// - Qwen think 标签剥离
/// - 流式输出
///
/// ChatProvider 只依赖 [DialogueEngine] 接口，不感知底层实现。
class SocraticPrompter implements DialogueEngine {
  final LlamaService _llm;

  /// 轮次计数，用于追问维度轮换
  int _roundIndex = 0;

  /// 最近 3 轮的问题（用于检测重复）
  final List<String> _recentQuestions = [];

  SocraticPrompter(this._llm);

  // ================================================================
  // DialogueEngine 接口实现
  // ================================================================

  @override
  bool get isReady => _llm.isLoaded;

  @override
  Future<bool> initialize() async {
    // 模型由外部加载（ChatPage 在 initState 中调用 LlamaService.loadModel）
    // 这里只设置系统提示词
    if (!_llm.isLoaded) return false;
    _llm.setSystemPrompt(_socraticSystemPrompt);
    return true;
  }

  @override
  void seedContext(String welcomeMessage) {
    _llm.addAssistantMessage(welcomeMessage);
  }

  @override
  Stream<String> generateResponse(String userMessage) async* {
    String dimension = _getCurrentDimension();
    final formattedMessage = '追问维度：【$dimension】\n$userMessage';

    _llm.addUserMessage(formattedMessage);

    String? finalReply;

    for (int attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        _llm.addUserMessage(
          '请基于【$dimension】维度，换一个角度追问，不要重复之前的问题。',
        );
      }

      final buffer = StringBuffer();
      try {
        await for (final token in _llm.generate(
          temperature: 0.85,
          topP: 0.92,
          maxTokens: 256,
        )) {
          buffer.write(token);
        }
      } catch (e, stack) {
        debugPrint('[SocraticPrompter] generate 异常: $e');
        debugPrintStack(stackTrace: stack);
        yield '[生成错误: $e]';
        return;
      }

      final fullReply = _stripThinkingTags(buffer.toString());

      if (fullReply.isEmpty && attempt < 2) {
        debugPrint(
          '[SocraticPrompter] 模型仅输出 think 内容，重试 (attempt=$attempt)',
        );
        _roundIndex++;
        dimension = _getCurrentDimension();
        continue;
      }

      if (attempt < 2 && _isDuplicateQuestion(fullReply)) {
        debugPrint(
          '[SocraticPrompter] 检测到重复问题，切换维度重试 (attempt=$attempt)',
        );
        _roundIndex++;
        dimension = _getCurrentDimension();
        continue;
      }

      finalReply = fullReply;
      break;
    }

    _roundIndex++;

    if (finalReply != null && finalReply.isNotEmpty) {
      _addToHistory(finalReply);
      // 逐字 yield，模拟流式效果
      for (int i = 0; i < finalReply.length; i++) {
        yield finalReply[i];
        if (i < finalReply.length - 1) {
          await Future.delayed(const Duration(milliseconds: 8));
        }
      }
    }
  }

  @override
  void reset() {
    _llm.clearHistory();
    _llm.setSystemPrompt(_socraticSystemPrompt);
    _roundIndex = 0;
    _recentQuestions.clear();
  }

  @override
  void dispose() {
    _llm.dispose();
    _roundIndex = 0;
    _recentQuestions.clear();
  }

  // ================================================================
  // 追问维度管理
  // ================================================================

  String _getCurrentDimension() =>
      _dimensions[_roundIndex % _dimensions.length];

  /// 去除 Qwen3.5 的 think 标签及推理内容，只保留最终回复。
  String _stripThinkingTags(String text) {
    final trimmed = text.trim();

    final closeIdx1 = trimmed.indexOf('</think>');
    final closeIdx2 = trimmed.indexOf('</思考>');
    final closeIdx = _minIdx(closeIdx1, closeIdx2);
    if (closeIdx != -1) {
      final tagLen = closeIdx == closeIdx1 ? 8 : 6;
      final after = trimmed.substring(closeIdx + tagLen).trim();
      if (after.isNotEmpty) return after;
    }

    if (trimmed.startsWith('<think>') || trimmed.startsWith('<思考>')) {
      return '';
    }

    return trimmed;
  }

  static int _minIdx(int a, int b) {
    if (a == -1) return b;
    if (b == -1) return a;
    return a < b ? a : b;
  }

  /// 计算两个问题的关键词相似度（简单去重检测）
  double _questionSimilarity(String a, String b) {
    final cleanA = a.replaceAll(RegExp(r'[？，。！\s]'), '');
    final cleanB = b.replaceAll(RegExp(r'[？，。！\s]'), '');
    if (cleanA.isEmpty || cleanB.isEmpty) return 0;

    int maxLen = 0;
    for (int i = 0; i < cleanA.length; i++) {
      for (int j = 0; j < cleanB.length; j++) {
        int len = 0;
        while (i + len < cleanA.length &&
            j + len < cleanB.length &&
            cleanA[i + len] == cleanB[j + len]) {
          len++;
        }
        if (len > maxLen) maxLen = len;
      }
    }
    return maxLen / cleanA.length;
  }

  bool _isDuplicateQuestion(String question) {
    for (final recent in _recentQuestions) {
      if (_questionSimilarity(question, recent) > 0.6) return true;
    }
    return false;
  }

  void _addToHistory(String question) {
    _recentQuestions.add(question);
    if (_recentQuestions.length > 3) _recentQuestions.removeAt(0);
  }
}
