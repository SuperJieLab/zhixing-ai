import 'package:dio/dio.dart';

/// 云端单次补全（BYOK 非流式）：`POST {baseUrl}/chat/completions`。
///
/// 单次补全通道的云端唯一实现——服务 `_defaultCloudAsk`（`ask` /
/// `askJson` / 摘要经 [SingleShotSummarizer] 注入）都走这里，只差提示词
/// 与输出上限。
///
/// 异常语义：网络 / HTTP 错误抛带状态码的 [Exception]；响应缺
/// `choices[0].message.content` 视为畸形响应并抛错（不静默产出空文本）。
class CloudCompletionRequest {
  final Dio _dio;
  final String _apiKey;
  final String _modelName;

  /// [dio] 仅测试注入；生产用 [baseUrl] 自建（容忍尾斜杠）。
  CloudCompletionRequest({
    required String baseUrl,
    required String apiKey,
    required String modelName,
    Dio? dio,
  })  : _apiKey = apiKey, // ignore: prefer_initializing_formals
        _modelName = modelName, // ignore: prefer_initializing_formals
        _dio = dio ??
            Dio(BaseOptions(
              baseUrl: baseUrl.replaceAll(RegExp(r'/+$'), ''),
              responseType: ResponseType.json,
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 30),
            ));

  /// 单次补全：返回 `choices[0].message.content` 原文（**不剥 think**，
  /// 剥离策略归调用方——云端 `ask` 剥、askJson 在解析前剥）。
  ///
  /// [maxTokens] 为 null 时不下发该字段（用厂商默认）。
  Future<String> complete({
    required String system,
    required String user,
    int? maxTokens,
  }) async {
    final body = {
      'model': _modelName,
      'messages': [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': user},
      ],
      'stream': false,
      'max_tokens': ?maxTokens,
    };

    Response<Map<String, dynamic>> resp;
    try {
      resp = await _dio.post<Map<String, dynamic>>(
        '/chat/completions',
        data: body,
        options: Options(headers: {'Authorization': 'Bearer $_apiKey'}),
      );
    } on DioException catch (e) {
      // 非 2xx 也走 DioException：带上 status 便于日志定位（401/429/欠费）。
      final status = e.response?.statusCode;
      throw Exception('云端补全请求失败${status != null ? '（HTTP $status）' : ''}'
          ': ${e.message ?? e.type.name}');
    }

    return extractContent(resp.data);
  }

  /// 取非流式回复正文：`choices[0].message.content`。
  /// 缺字段即视为畸形响应并抛错。
  static String extractContent(Map<String, dynamic>? data) {
    final choices = data?['choices'];
    if (choices is! List || choices.isEmpty) {
      throw Exception('云端补全响应缺少 choices');
    }
    final first = choices.first;
    final message = first is Map ? first['message'] : null;
    final content = message is Map ? message['content'] : null;
    if (content is! String || content.trim().isEmpty) {
      throw Exception('云端补全响应缺少 content');
    }
    return content;
  }
}
