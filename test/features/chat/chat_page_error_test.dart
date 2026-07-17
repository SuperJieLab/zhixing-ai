import 'package:flutter_test/flutter_test.dart';
import 'package:zhixing_ai/features/chat/providers/chat_provider.dart';

/// ChatProvider 错误状态 API 的单元测试
ChatProvider makeProvider({String topic = '测试'}) => ChatProvider(topic: topic);

void main() {
  group('ChatProvider error state', () {
    test('hasModelError 初始为 false', () {
      final provider = makeProvider();
      expect(provider.hasModelError, false);
    });

    test('modelError 初始为 null', () {
      final provider = makeProvider();
      expect(provider.modelError, isNull);
    });

    test('hasModelError 与 modelError 一致', () {
      final provider = makeProvider();
      expect(provider.hasModelError, false);
      expect(provider.modelError, isNull);
    });

    test('error（推理错误）初始为 null', () {
      final provider = makeProvider();
      expect(provider.error, isNull);
    });

    test('clearError 可正常调用且不崩溃', () {
      final provider = makeProvider();
      expect(provider.error, isNull);
      provider.clearError();
      expect(provider.error, isNull);
    });

    test('retryLoadModel 方法存在', () {
      final provider = makeProvider();
      final result = provider.retryLoadModel();
      expect(result, isA<Future<void>>());
    });
  });

  group('ChatProvider 对话错误处理', () {
    test('sendMessage 在无引擎时使用 Mock 回复且不设置 error', () async {
      final provider = makeProvider();
      await provider.sendMessage('你好');
      expect(provider.messages.length, 3);
      expect(provider.error, isNull);
    });
  });
}
