import 'package:dio/dio.dart';
import 'package:zhixing_ai/core/data/models/chat_models.dart';
import 'package:zhixing_ai/core/llm/think_tag_stripper.dart';
import 'package:zhixing_ai/features/chat/engine/context_policy.dart';
import 'package:zhixing_ai/features/chat/engine/conversation_strategy.dart';

/// 云端摘要器（策略位④）：复用同一 BYOK 端点，**非流式**小请求。
///
/// 端侧摘要走本地 2B 模型（零成本、离线，但质量有限）；云端既然已经付费，
/// 摘要就直接用同一个云端模型做——这是「能力对等、策略不同」中
/// 「摘要器实现不同」的直接体现。
///
/// 请求形态：`POST {baseUrl}/chat/completions`，`stream: false` + 小
/// `max_tokens`（摘要本就要压缩成一段话）。异常一律向上抛，由
/// [BaseContextPolicy] 兜底回落（保留旧摘要、被移出消息静默丢弃）。
class CloudSummarizer implements ConversationSummarizer {
  /// 摘要请求的输出上限：摘要目标 ≤200 字，512 足够且省钱。
  static const int maxTokens = 512;

  final Dio _dio;
  final String _apiKey;
  final String _modelName;

  /// [dio] 仅测试注入；生产用 [baseUrl] 自建（容忍尾斜杠）。
  CloudSummarizer({
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

  @override
  Future<String> summarize(
      String previousSummary, List<ChatMessage> evicted) async {
    // 提示词与端侧共用同一纯函数：摘要口径（保留什么、压缩到多少字）双端一致。
    final prompt = ConversationStrategy.buildSummaryPrompt(
      previousSummary: previousSummary,
      dropped:
          evicted.map((m) => (role: m.role.name, content: m.content)).toList(),
    );

    final body = {
      'model': _modelName,
      'messages': [
        {'role': 'system', 'content': prompt},
        {'role': 'user', 'content': '请输出摘要。'},
      ],
      'stream': false,
      'max_tokens': maxTokens,
      // temperature 用厂商默认：摘要对随机性不敏感，无需额外下发。
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
      throw Exception('云端摘要请求失败${status != null ? '（HTTP $status）' : ''}'
          ': ${e.message ?? e.type.name}');
    }

    return stripThinkTags(_extractContent(resp.data));
  }

  /// 取非流式回复正文：`choices[0].message.content`。
  /// 缺字段即视为畸形响应并抛错（由策略兜底回落，不静默产出空摘要）。
  static String _extractContent(Map<String, dynamic>? data) {
    final choices = data?['choices'];
    if (choices is! List || choices.isEmpty) {
      throw Exception('云端摘要响应缺少 choices');
    }
    final first = choices.first;
    final message = first is Map ? first['message'] : null;
    final content = message is Map ? message['content'] : null;
    if (content is! String || content.trim().isEmpty) {
      throw Exception('云端摘要响应缺少 content');
    }
    return content;
  }
}
