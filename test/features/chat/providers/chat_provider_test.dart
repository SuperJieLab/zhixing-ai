import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhixing_ai/core/data/conversation_service.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/data/models/conversation.dart';
import 'package:zhixing_ai/core/data/models/dashboard_models.dart';
import 'package:zhixing_ai/core/data/repository/dashboard_repository.dart';
import 'package:zhixing_ai/core/data/repository/settings_repository.dart';
import 'package:zhixing_ai/features/chat/providers/chat_provider.dart';

import '../../../support/fake_llm.dart';

/// ChatProvider 单元测试
///
/// 传入 dummy Conversation(id: 1) 使 _activeConversationId 不为 null，
/// sendMessage() 就不会触发 startConversation() → DB 操作。
/// 避免在 macOS 测试环境中依赖 sqflite（需要 sqflite_common_ffi）。
///
/// 注意：每次 makeProvider 新建 Conversation——ChatProvider 会把
/// conversation.messages 当作内部列表就地变更，共享实例会泄漏状态到后续测试。

Conversation _dummyConv() => Conversation(
      id: 1,
      topic: 'test',
      // 显式给可增长列表：默认值是 const []（不可变），
      // ChatProvider 会把它当作内部消息列表就地 add，会抛 UnsupportedError
      messages: <ChatMessage>[],
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

/// no-op 持久化：跳过 sendMessage finally 里的 saveMessages → DB 落库
class _NoopConversationService extends ConversationService {
  @override
  Future<void> saveMessages(
          int conversationId, List<ChatMessage> messages) async {}
}

/// 记录型持久化：捕获 saveMessages 调用（id + 消息快照）
class _RecordingConversationService extends ConversationService {
  final List<({int id, List<ChatMessage> messages})> saves = [];

  @override
  Future<void> saveMessages(
      int conversationId, List<ChatMessage> messages) async {
    saves.add((id: conversationId, messages: List.of(messages)));
  }
}

/// 目标仓库 fake：返回空目标（load 不依赖 DB）
class _OkDashboardRepo extends DashboardRepository {
  @override
  Future<List<Goal>> getActiveGoals() async => const [];
}

/// 目标仓库 fake：返回一个已有目标（验证「目标注入人设」留在业务侧）
class _GoalsDashboardRepo extends DashboardRepository {
  @override
  Future<List<Goal>> getActiveGoals() async => [
        Goal(
          title: '学英语',
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
        ),
      ];
}

/// 目标仓库 fake：模拟测试环境无 DB（getActiveGoals 抛错）
class _FailingDashboardRepo extends DashboardRepository {
  @override
  Future<List<Goal>> getActiveGoals() async => throw StateError('no db');
}

void main() {
  // ChatProvider 构造时读取 chatCloudMode，须先初始化 SettingsRepository
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await SettingsRepository.instance.initialize();
  });

  ChatProvider makeProvider({
    String topic = 'test',
    bool skipDb = true,
    FakeLlm? llm,
    DashboardRepository? dashboardRepo,
    ConversationService? conversationService,
  }) =>
      ChatProvider(
        topic: topic,
        conversation: skipDb ? _dummyConv() : null,
        conversationService: conversationService ?? _NoopConversationService(),
        llm: llm ?? FakeLlm(),
        dashboardRepo: dashboardRepo,
      );

  group('ChatProvider', () {
    test('初始化时包含一条 AI 欢迎消息（轮次 0）', () {
      // skipDb: false → 不传 conversation，使用 _buildWelcome
      final provider = makeProvider(topic: '职业发展', skipDb: false);
      expect(provider.messages.length, 1);
      expect(provider.messages.first.role, MessageRole.ai);
      expect(provider.messages.first.round, 0);
      expect(provider.messages.first.content, contains('职业'));
    });

    test('发送消息后，消息列表包含用户消息和 AI 回复', () async {
      final provider = makeProvider(topic: '职业发展');
      await provider.sendMessage('我想转管理');
      // 恢复会话路径不加欢迎语：仅本轮 user + AI 两条
      expect(provider.messages.length, 2);
      expect(provider.messages[0].role, MessageRole.user);
      expect(provider.messages[0].content, '我想转管理');
      expect(provider.messages[0].round, 1);
      expect(provider.messages[1].role, MessageRole.ai);
    });

    test('Mock 模式下 isThinking 最终为 false', () async {
      final provider = makeProvider();
      expect(provider.isThinking, false);
      await provider.sendMessage('hello');
      expect(provider.isThinking, false);
    });

    test('每轮对话后 round 计数增加', () async {
      final provider = makeProvider();
      expect(provider.round, 1);
      await provider.sendMessage('answer 1');
      expect(provider.round, 2);
      await provider.sendMessage('answer 2');
      expect(provider.round, 3);
    });

    test('messages 返回不可变列表', () {
      final provider = makeProvider(skipDb: false);
      expect(
        () => provider.messages.add(const ChatMessage(
          role: MessageRole.user, content: 'hack', round: 99,
        )),
        throwsUnsupportedError,
      );
    });
  });

  group('ChatProvider × Llm 接入', () {
    test('loadModel：ensureReady 成功 → isModelReady', () async {
      final llm = FakeLlm();
      final provider = makeProvider(llm: llm, dashboardRepo: _OkDashboardRepo());

      expect(provider.isModelReady, isFalse);
      await provider.loadModel();
      expect(provider.isModelReady, isTrue);
      expect(provider.hasModelError, isFalse);
      expect(llm.ensureReadyCalls, 1);
    });

    test('loadModel：目标仓库失败 → modelError（不阻塞 mock 路径）', () async {
      final llm = FakeLlm();
      final provider = makeProvider(
        llm: llm,
        dashboardRepo: _FailingDashboardRepo(),
      );

      await provider.loadModel();
      expect(provider.hasModelError, isTrue);
      expect(provider.isModelReady, isFalse);
      // 目标读取失败即短路，不再触碰后端
      expect(llm.ensureReadyCalls, 0);
    });

    test('人设每轮注入已有目标（目标读取留在业务侧）', () async {
      final llm = FakeLlm();
      final provider = makeProvider(
        llm: llm,
        dashboardRepo: _GoalsDashboardRepo(),
      );
      await provider.loadModel();

      llm.onConverse = (_) => Stream.value('回复');
      await provider.sendMessage('hi');

      final prompt = llm.converseCalls.single.systemPrompt;
      expect(prompt, contains('## 用户已有目标'));
      expect(prompt, contains('[active] 学英语'));
    });

    test('流式回复逐段写回 AI 消息，历史尾部为本轮用户消息', () async {
      final llm = FakeLlm();
      final provider = makeProvider(
        llm: llm,
        dashboardRepo: _OkDashboardRepo(),
      );
      await provider.loadModel();
      final controller = StreamController<String>();

      final seen = <String>[];
      provider.addListener(() {
        final msgs = provider.messages;
        if (msgs.isNotEmpty && msgs.last.role == MessageRole.ai) {
          seen.add(msgs.last.content);
        }
      });

      llm.onConverse = (_) => controller.stream;
      final sendFuture = provider.sendMessage('我想转管理');
      await Future<void>.delayed(Duration.zero);

      controller.add('你'); // 逐段流出
      await Future<void>.delayed(Duration.zero);
      controller.add('好');
      await Future<void>.delayed(Duration.zero);
      await controller.close();
      await sendFuture;

      expect(provider.messages.last.content, '你好');
      expect(seen, contains('你')); // 中间态曾被写回
      // 历史 = 去掉尾部空 AI 占位符 → 尾部是本轮用户消息
      final call = llm.converseCalls.single;
      expect(call.history.last.role, MessageRole.user);
      expect(call.history.last.content, '我想转管理');
      expect(call.history.where((m) => m.content.isEmpty), isEmpty);
    });

    test('压缩状态实例由业务持有并跨轮复用（类型在基建、实例在业务）', () async {
      final llm = FakeLlm();
      final provider = makeProvider(llm: llm, dashboardRepo: _OkDashboardRepo());
      await provider.loadModel();
      llm.onConverse = (_) => Stream.value('回复');

      await provider.sendMessage('a');
      await provider.sendMessage('b');

      expect(llm.converseCalls.length, 2);
      expect(llm.converseCalls[0].state, same(llm.converseCalls[1].state));
    });

    test('stopGeneration：半截内容保留，正常收尾且转发 stop 到服务', () async {
      final llm = FakeLlm();
      final provider = makeProvider(
        llm: llm,
        dashboardRepo: _OkDashboardRepo(),
      );
      await provider.loadModel();
      final gate = Completer<void>();

      llm.onConverse = (_) async* {
        yield '部分';
        await gate.future;
        yield '后半';
      };

      final sendFuture = provider.sendMessage('长问题');
      await Future<void>.delayed(Duration.zero);
      expect(provider.messages.last.content, '部分');

      provider.stopGeneration();
      await sendFuture; // 不应抛异常：finally 正常推进

      expect(provider.messages.last.content, '部分'); // 半截保留
      expect(provider.isThinking, isFalse);
      expect(provider.round, 2); // 轮次已推进
      expect(provider.error, isNull); // 未进降级分支
      expect(llm.stopCalls, 1);
      gate.complete(); // 清理挂起的生成器
    });

    test('TimeoutException → 固定超时文案', () async {
      final llm = FakeLlm();
      final provider = makeProvider(
        llm: llm,
        dashboardRepo: _OkDashboardRepo(),
      );
      await provider.loadModel();

      llm.onConverse = (_) async* {
        throw TimeoutException('帧间空闲');
      };

      await provider.sendMessage('hi');
      expect(provider.messages.last.content, '连接超时了，请重新发送你的问题。');
      expect(provider.error, '连接超时');
    });

    test('空内容异常 → Mock 降级', () async {
      final llm = FakeLlm();
      final provider = makeProvider(
        llm: llm,
        dashboardRepo: _OkDashboardRepo(),
      );
      await provider.loadModel();

      llm.onConverse = (_) async* {
        throw StateError('boom');
      };

      await provider.sendMessage('hi');
      expect(provider.error, '连接失败，已使用本地回复');
      expect(provider.messages.last.content, isNotEmpty);
    });

    test('每轮流式结束后持久化消息', () async {
      final llm = FakeLlm();
      final service = _RecordingConversationService();
      final provider = makeProvider(
        llm: llm,
        conversationService: service,
        dashboardRepo: _OkDashboardRepo(),
      );
      await provider.loadModel();

      llm.onConverse = (history) => Stream.value('回复');
      await provider.sendMessage('hi');

      expect(service.saves.length, 1);
      expect(service.saves.single.id, 1);
      expect(service.saves.single.messages.length, 2); // user + ai
    });
  });

  group('ChatMessage', () {
    test('字段正确赋值', () {
      const msg =
          ChatMessage(role: MessageRole.user, content: 'hello', round: 3);
      expect(msg.role, MessageRole.user);
      expect(msg.content, 'hello');
      expect(msg.round, 3);
    });
  });
}
