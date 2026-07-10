import 'package:flutter_test/flutter_test.dart';
import 'package:socratic_ai/features/model_manager/providers/model_download_provider.dart';

void main() {
  group('ModelDownloadProvider formatting', () {
    test('formatBytes formats all sizes correctly', () {
      expect(ModelDownloadProvider.formatBytes(0), '0 B');
      expect(ModelDownloadProvider.formatBytes(500), '500 B');
      expect(ModelDownloadProvider.formatBytes(1024), '1.0 KB');
      expect(ModelDownloadProvider.formatBytes(1536), '1.5 KB');
      expect(ModelDownloadProvider.formatBytes(1048576), '1.0 MB');
      expect(ModelDownloadProvider.formatBytes(3145728), '3.0 MB');
      expect(ModelDownloadProvider.formatBytes(1073741824), '1.00 GB');
    });

    test('formatSpeed formats all speeds correctly', () {
      expect(ModelDownloadProvider.formatSpeed(0), '0 B/s');
      expect(ModelDownloadProvider.formatSpeed(500), '500 B/s');
      expect(ModelDownloadProvider.formatSpeed(2048), '2.0 KB/s');
      expect(ModelDownloadProvider.formatSpeed(5242880), '5.0 MB/s');
    });

    test('formatEta formats all durations correctly', () {
      expect(ModelDownloadProvider.formatEta(30), '剩余 30 秒');
      expect(ModelDownloadProvider.formatEta(90), '剩余 1 分钟');
      expect(ModelDownloadProvider.formatEta(300), '剩余 5 分钟');
      expect(ModelDownloadProvider.formatEta(3661), '剩余 1 小时');
    });
  });

  group('ModelDownloadProvider state', () {
    test('initial state returns idle for unknown model', () {
      final provider = ModelDownloadProvider();
      addTearDown(provider.dispose);

      final state = provider.stateOf('unknown-model');
      expect(state.status, DownloadStatus.idle);
      expect(state.progress, 0.0);
      expect(state.error, isNull);
      expect(state.receivedBytes, 0);
      expect(state.totalBytes, 0);
    });

    test('activeModelId is null initially', () {
      final provider = ModelDownloadProvider();
      addTearDown(provider.dispose);

      expect(provider.activeModelId, isNull);
    });
  });
}
