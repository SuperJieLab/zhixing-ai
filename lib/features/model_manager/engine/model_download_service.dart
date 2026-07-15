import 'dart:io';

import 'package:dio/dio.dart';

import 'package:socratic_ai/core/logger.dart';

/// 下载进度回调
typedef DownloadProgress = void Function({
  required int received,
  required int total,
});

/// 模型下载服务
///
/// 使用 dio HTTP Range 实现断点续传。
/// 由 [ModelDownloadProvider] 创建并管理生命周期。
class ModelDownloadService {
  ModelDownloadService();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(minutes: 30),
    followRedirects: true,
    maxRedirects: 10,
  ));

  CancelToken? _cancelToken;

  /// 下载模型到 [savePath]，Range 头支持断点续传。
  ///
  /// 返回 true 表示完成，false 表示取消，异常表示失败。
  Future<bool> download({
    required String url,
    required String savePath,
    DownloadProgress? onProgress,
  }) async {
    _cancelToken = CancelToken();

    final file = File(savePath);
    final startByte = await file.exists() ? await file.length() : 0;

    AppLogger.info('ModelDownload', '开始下载: $url');
    AppLogger.info('ModelDownload', '保存路径: $savePath');
    AppLogger.info('ModelDownload', '断点续传起始: $startByte bytes');

    final headers = <String, dynamic>{};
    if (startByte > 0) {
      headers['Range'] = 'bytes=$startByte-';
      AppLogger.info('ModelDownload', 'Range 头: bytes=$startByte-');
    }

    try {
      final response = await _dio.download(
        url,
        savePath,
        options: Options(
          headers: headers,
          responseType: ResponseType.stream,
        ),
        cancelToken: _cancelToken,
        onReceiveProgress: (received, total) {
          onProgress?.call(
            received: startByte + received,
            total: startByte + total,
          );
        },
      );

      AppLogger.info('ModelDownload', '完成, statusCode=${response.statusCode}');
      return response.statusCode == 200 || response.statusCode == 206;
    } on DioException catch (e) {
      AppLogger.error('ModelDownload', 'DioException type=${e.type}, message=${e.message}, error=${e.error}, url=${e.requestOptions.uri}');
      if (e.type == DioExceptionType.cancel) return false;

      // 416 Range Not Satisfiable: file is already fully downloaded,
      // just mark as complete.
      if (e.response?.statusCode == 416) {
        AppLogger.info('ModelDownload', '416: 文件已完整下载，跳过');
        return true;
      }

      rethrow;
    }
  }

  void cancel() {
    _cancelToken?.cancel();
    _cancelToken = null;
  }
}
