import 'package:dio/dio.dart';
import 'package:zhixing_ai/core/constants.dart';
import 'package:zhixing_ai/core/logger.dart';
import 'package:zhixing_ai/core/models/dashboard_models.dart';
import 'package:zhixing_ai/core/repository/settings_repository.dart';
import 'package:zhixing_ai/core/services/push_service.dart';

// ============================================================
// SyncService — 数据同步服务（端侧 → 服务端）
// ============================================================
//
// 【这个文件做什么】
// 把 Dashboard 的 Goal + Strategy 数据打包成 JSON，通过 HTTP POST 发到服务端。
// 服务端拿到数据后做推送决策（规则模式或 LLM 模式）。
//
// 【在架构中的位置】
//   DashboardProvider.load() → _syncToServer() → SyncService.syncDashboard()
//                                                        ↓
//                                               POST /api/sync → 服务端
//
// 【调用时机】
//   每次 DashboardProvider.load() 完成后自动触发（包括首次加载、状态变更后重新加载）
//   ——不需要手动调，对业务代码透明。
//
// 【数据格式】
//   POST http://localhost:3000/api/sync
//   {
//     device_token: "xxx",    // 来自 PushService
//     mode: "rules" | "llm",  // 来自「AI 优化推送」设置开关
//     goals: [{ title, category, status, deadline, priority }],
//     strategies: [{ description, goal_id, completed }]
//   }
//
// 【容错设计】
//   服务端不可用时 catch 后用 AppLogger 记录，不影响 App 正常运行
//   ——推送是"锦上添花"，不是核心功能，不能因为推送服务挂了 App 就崩
//
// 【面试可聊】
//   - 为什么用单例 + 公开字段而非 Provider？→ SyncService 不驱动 UI，只是副作用
//   - 为什么 connectionTimeout 5 秒？→ 移动端网络不稳定，快速失败优于长时间等待
//   - 隐私：上传的是结构化摘要（title/deadline），不传对话原文
//
// 【依赖】
//   - dio（HTTP 客户端）
//   - PushService（获取 device token）
//   - DashboardModels（Goal / Strategy 数据模型）

class SyncService {
  static final SyncService _instance = SyncService._();
  factory SyncService() => _instance;
  SyncService._();

  final Dio _dio = Dio(BaseOptions(
    baseUrl: AppConstants.serverBaseUrl,
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 5),
  ));

  /// 同步 Dashboard 数据到服务端
  Future<void> syncDashboard({
    required List<Goal> goals,
    required List<Strategy> strategies,
  }) async {
    final token = await PushService().getToken();
    if (token == null) return;

    try {
      await _dio.post('/api/sync', data: {
        'device_token': token,
        'mode': SettingsRepository.instance.useAiOptimizedPush ? 'llm' : 'rules',
        'goals': goals.map((g) => {
          'title': g.title,
          'category': g.category.name,
          'status': g.status.name,
          'deadline': g.deadline,
          'priority': g.priority,
        }).toList(),
        'strategies': strategies.map((s) => {
          'description': s.description,
          'goal_id': s.goalId,
          'completed': s.completed,
        }).toList(),
      });
      AppLogger.info('Sync', '数据同步完成');
    } catch (e) {
      AppLogger.info('Sync', '数据同步失败（服务端可能未启动）: $e');
    }
  }
}
