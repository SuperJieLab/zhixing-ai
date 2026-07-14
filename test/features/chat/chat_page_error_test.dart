import 'package:flutter_test/flutter_test.dart';
import 'package:socratic_ai/features/chat/providers/chat_provider.dart';

/// ChatProvider 错误状态 API 的单元测试
///
/// 验证 ChatProvider 的错误处理相关 getter 和方法存在且初始状态正确。
/// 由于 loadModel 依赖 LlamaService（在测试环境中不可用），
/// 这里聚焦于同步可验证的错误状态 API。
void main() {
  group('ChatProvider error state', () {
    test('hasModelError 初始为 false', () {
      final provider = ChatProvider(topic: '测试');
      expect(provider.hasModelError, false);
    });

    test('modelError 初始为 null', () {
      final provider = ChatProvider(topic: '测试');
      expect(provider.modelError, isNull);
    });

    test('hasModelError 与 modelError 一致', () {
      final provider = ChatProvider(topic: '测试');
      expect(provider.hasModelError, false);
      expect(provider.modelError, isNull);
    });

    test('error（推理错误）初始为 null', () {
      final provider = ChatProvider(topic: '测试');
      expect(provider.error, isNull);
    });

    test('clearError 可正常调用且不崩溃', () {
      final provider = ChatProvider(topic: '测试');
      expect(provider.error, isNull);
      provider.clearError();
      expect(provider.error, isNull);
    });

    test('retryLoadModel 方法存在', () {
      final provider = ChatProvider(topic: '测试');
      // 验证方法存在且返回 Future<void>
      final result = provider.retryLoadModel();
      expect(result, isA<Future<void>>());
    });
  });

  group('ChatProvider 对话错误处理', () {
    test('sendMessage 在无引擎时使用 Mock 回复且不设置 error', () async {
      final provider = ChatProvider(topic: '测试');
      // 引擎未加载，sendMessage 应回退到 Mock 回复
      await provider.sendMessage('你好');

      // 应该有用户消息 + AI 回复
      expect(provider.messages.length, 3);
      expect(provider.error, isNull);
    });
  });
}
