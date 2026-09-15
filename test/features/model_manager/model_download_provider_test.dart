import 'package:flutter_test/flutter_test.dart';
import 'package:zhixing_ai/core/data/models/available_model.dart';
import 'package:zhixing_ai/core/llm/engine/active_model_manager.dart';
import 'package:zhixing_ai/features/model_manager/providers/model_download_provider.dart';

void main() {
  // 三个格式化纯函数合并为一个用例：它们只是显示口径，拆成三个用例
  // 不增加保护力。
  test('下载进度显示口径（字节 / 速率 / 剩余时间）', () {
    expect(ModelDownloadProvider.formatBytes(0), '0 B');
    expect(ModelDownloadProvider.formatBytes(500), '500 B');
    expect(ModelDownloadProvider.formatBytes(1024), '1.0 KB');
    expect(ModelDownloadProvider.formatBytes(1536), '1.5 KB');
    expect(ModelDownloadProvider.formatBytes(1048576), '1.0 MB');
    expect(ModelDownloadProvider.formatBytes(3145728), '3.0 MB');
    expect(ModelDownloadProvider.formatBytes(1073741824), '1.00 GB');

    expect(ModelDownloadProvider.formatSpeed(0), '0 B/s');
    expect(ModelDownloadProvider.formatSpeed(500), '500 B/s');
    expect(ModelDownloadProvider.formatSpeed(2048), '2.0 KB/s');
    expect(ModelDownloadProvider.formatSpeed(5242880), '5.0 MB/s');

    expect(ModelDownloadProvider.formatEta(30), '剩余 30 秒');
    expect(ModelDownloadProvider.formatEta(90), '剩余 1 分钟');
    expect(ModelDownloadProvider.formatEta(300), '剩余 5 分钟');
    expect(ModelDownloadProvider.formatEta(3661), '剩余 1 小时');
  });

  group('ModelDownloadProvider state', () {
    test('initial state returns idle for unknown model', () {
      final provider = ModelDownloadProvider(manager: ActiveModelManager());
      addTearDown(provider.dispose);

      final state = provider.stateOf('unknown-model');
      expect(state.status, DownloadStatus.idle);
      expect(state.progress, 0.0);
      expect(state.error, isNull);
      expect(state.receivedBytes, 0);
      expect(state.totalBytes, 0);
    });

    test('注入的 manager 已下载状态同步到初始 state', () {
      final manager = ActiveModelManager();
      final model = AvailableModel.available.first;
      manager.setModelReady(model.id, '/tmp/${model.fileName}');

      final provider = ModelDownloadProvider(manager: manager);
      addTearDown(provider.dispose);

      expect(provider.stateOf(model.id).status, DownloadStatus.completed);
      expect(provider.stateOf(model.id).progress, 1.0);
    });
  });
}
