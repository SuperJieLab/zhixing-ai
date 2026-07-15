import 'dart:ui';

/// 对话消息角色
///
/// 替代原先的魔法字符串 'ai' / 'user'，
/// 提供编译期类型安全，防止拼写错误导致的静默 Bug。
enum MessageRole {
  /// AI 发出的消息（追问）
  ai,

  /// 用户发出的消息（回答）
  user,
}

/// 一条对话消息
///
/// 每条消息都有三个属性：
/// - [role]：谁说的？（ai 或 user）
/// - [content]：说了什么？
/// - [round]：发生在第几轮对话中？
///
/// 使用 const 构造函数，创建后不可变（immutable）。
/// 这避免了消息内容被意外修改导致的 Bug。
class ChatMessage {
  /// 消息角色
  final MessageRole role;

  /// 消息文本内容
  final String content;

  /// 所属的对话轮次
  ///
  /// 欢迎消息为第 0 轮（序言），第一轮用户问答为第 1 轮，
  /// 以此类推。同一轮对话中，用户消息和 AI 回复共享相同的 round 值。
  final int round;

  /// 创建一个不可变的消息实例
  const ChatMessage({
    required this.role,
    required this.content,
    required this.round,
  });
}

/// 对话洞察结果（Day 4 产出）
///
/// 由对话总结 Prompt 产出的结构化洞察数据。
/// InsightsPage 只接收已解析好的 InsightResult，
/// 不接触原始对话记录。
class InsightResult {
  /// 核心洞察列表，如「你重视『不后悔』胜过『不失败』」
  final List<String> coreInsights;

  /// 底层价值观标签，如 ['勇气', '自由', '安全感']
  final List<String> underlyingValues;

  /// 发现的认知矛盾，如「你说想要安稳，但又渴望冒险」
  final List<String> contradictionsFound;

  /// 建议的下一个话题（可为 null）
  final String? nextTopicSuggestion;

  const InsightResult({
    required this.coreInsights,
    required this.underlyingValues,
    required this.contradictionsFound,
    this.nextTopicSuggestion,
  });
}

/// 图谱节点 — 一个概念/洞察/话题
///
/// [label] 显示文本，[type] 节点分类（影响颜色），[weight] 重要性权重（影响大小）。
/// [x] [y] 布局后的画布坐标（0-1 归一化），布局前为 null。
/// [radius] 渲染半径（布局计算得出，与 weight 成正比）。
class GraphNode {
  final String id;
  final String label;
  final String type; // 'topic' | 'insight' | 'value' | 'action' | 'contradiction'
  final double weight; // 0-1，布局时用于斥力计算
  double? x;
  double? y;
  double? radius;
  double? vx; // 速度向量（布局迭代用）
  double? vy;

  GraphNode({
    required this.id,
    required this.label,
    required this.type,
    this.weight = 0.5,
    this.x,
    this.y,
    this.radius,
    this.vx,
    this.vy,
  });

  factory GraphNode.fromJson(Map<String, dynamic> json) {
    return GraphNode(
      id: json['id'] as String? ?? '',
      label: json['label'] as String? ?? '',
      type: json['type'] as String? ?? 'insight',
      weight: (json['weight'] as num?)?.toDouble() ?? 0.5,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'type': type,
        'weight': weight,
      };

  /// 节点类型 → 描边颜色
  static Color strokeColor(String type) {
    switch (type) {
      case 'topic':
        return const Color(0xFF5B6D5B);
      case 'insight':
        return const Color(0xFF5B8D8D);
      case 'value':
        return const Color(0xFF8B7355);
      case 'action':
        return const Color(0xFFD4A574);
      case 'contradiction':
        return const Color(0xFFD4735B);
      default:
        return const Color(0xFF5B6D5B);
    }
  }

  /// 节点类型 → 填充颜色
  static Color fillColor(String type) {
    switch (type) {
      case 'topic':
        return const Color(0xFFE8EFE8);
      case 'insight':
        return const Color(0xFFE0EDED);
      case 'value':
        return const Color(0xFFEDE4DA);
      case 'action':
        return const Color(0xFFFAEDDE);
      case 'contradiction':
        return const Color(0xFFFAE6E0);
      default:
        return const Color(0xFFE8EFE8);
    }
  }

  /// 节点类型 → 中文标签
  static String typeLabel(String type) {
    switch (type) {
      case 'topic':
        return '话题';
      case 'insight':
        return '洞察';
      case 'value':
        return '价值观';
      case 'action':
        return '行动';
      case 'contradiction':
        return '矛盾';
      default:
        return '';
    }
  }
}

/// 图谱连线 — 两个节点之间的关系
///
/// [source] [target] 是节点 id，[label] 是关系描述（如"推导出"、"包含"）。
/// [strength] 关系强度（影响连线粗细和布局吸引力）。
class GraphEdge {
  final String source;
  final String target;
  final String label;
  final double strength; // 0-1

  GraphEdge({
    required this.source,
    required this.target,
    this.label = '',
    this.strength = 0.5,
  });

  factory GraphEdge.fromJson(Map<String, dynamic> json) {
    return GraphEdge(
      source: json['source'] as String? ?? '',
      target: json['target'] as String? ?? '',
      label: json['label'] as String? ?? '',
      strength: (json['strength'] as num?)?.toDouble() ?? 0.5,
    );
  }

  Map<String, dynamic> toJson() => {
        'source': source,
        'target': target,
        'label': label,
        'strength': strength,
      };
}

/// 对话思维图谱 — 一次对话的完整图结构
///
/// 由 [GraphService] 通过 LLM 分析对话产出。
/// [MindMapPage] 接收并渲染。
class ConversationGraph {
  final List<GraphNode> nodes;
  final List<GraphEdge> edges;

  const ConversationGraph({this.nodes = const [], this.edges = const []});

  factory ConversationGraph.fromJson(Map<String, dynamic> json) {
    List<GraphNode> parseNodes(dynamic value) {
      if (value is List) {
        return value
            .map((e) => GraphNode.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      return [];
    }

    List<GraphEdge> parseEdges(dynamic value) {
      if (value is List) {
        return value
            .map((e) => GraphEdge.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      return [];
    }

    return ConversationGraph(
      nodes: parseNodes(json['nodes']),
      edges: parseEdges(json['edges']),
    );
  }

  Map<String, dynamic> toJson() => {
        'nodes': nodes.map((n) => n.toJson()).toList(),
        'edges': edges.map((e) => e.toJson()).toList(),
      };

  bool get isEmpty => nodes.isEmpty;
  bool get isNotEmpty => nodes.isNotEmpty;
  int get nodeCount => nodes.length;
  int get edgeCount => edges.length;
}
