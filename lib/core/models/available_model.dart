/// 可供下载的 AI 模型定义
///
/// 当前 APP 只支持一个活跃模型（下载即生效），
/// 但 [available] 列表预留了多模型扩展空间。
class AvailableModel {
  final String id;
  final String name;
  final String description;
  final String quant;
  final int sizeBytes;
  final String fileName;
  final String hfRepo;

  const AvailableModel({
    required this.id,
    required this.name,
    required this.description,
    required this.quant,
    required this.sizeBytes,
    required this.fileName,
    required this.hfRepo,
  });

  String get downloadUrl =>
      'https://huggingface.co/$hfRepo/resolve/main/$fileName';

  String get mirrorUrl =>
      'https://hf-mirror.com/$hfRepo/resolve/main/$fileName';

  /// 可用模型列表
  static const List<AvailableModel> available = [
    AvailableModel(
      id: 'qwen3.5-2b-q4km',
      name: 'Qwen3.5-2B',
      description: '中文苏格拉底对话，最新推荐',
      quant: 'Q4_K_M',
      sizeBytes: 1270808032,
      fileName: 'Qwen3.5-2B-Q4_K_M.gguf',
      hfRepo: 'lmstudio-community/Qwen3.5-2B-GGUF',
    ),
    AvailableModel(
      id: 'qwen2.5-1.5b-q4km',
      name: 'Qwen2.5-1.5B',
      description: '轻量端侧推理，体积更小',
      quant: 'Q4_K_M',
      sizeBytes: 1130000000,
      fileName: 'qwen2.5-1.5b-instruct-q4_k_m.gguf',
      hfRepo: 'Qwen/Qwen2.5-1.5B-Instruct-GGUF',
    ),
  ];
}
