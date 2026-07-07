# Day 6 — 思维图谱 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 端侧 LLM 将一次对话转化为可交互的节点关系图，Flutter CustomPainter 渲染 force-directed 布局，支持拖拽/缩放/点击交互。

**Architecture:** 新建 `GraphService`（复用 InsightService 模式：独立 EngineChat → LLM 输出 JSON → 三层回退解析），新建 `ConversationGraph` 数据模型，新建 `ForceDirectedLayout` 布局算法，新建 `MindMapPage` + `GraphPainter`（CustomPainter 渲染 + 手势交互）。InsightsPage 的「查看思维图谱」按钮从灰色变为可用，跳转 MindMapPage。

**Tech Stack:** Flutter CustomPainter + GestureDetector / llama.cpp (via LlamaService) / Dart / Provider

---

## 文件结构（改动范围）

```
lib/core/models/
└── chat_models.dart              # 新增: ConversationGraph, GraphNode, GraphEdge

lib/features/mindmap/             # 新建: 完整思维图谱 feature
├── engine/
│   └── graph_service.dart        # LLM 生成图谱 JSON
├── layout/
│   └── force_directed.dart       # Force-directed 布局算法
├── widgets/
│   ├── graph_painter.dart        # CustomPainter 渲染
│   └── node_detail_sheet.dart    # 节点详情底部弹窗
└── mindmap_page.dart             # 图谱页面（GestureDetector 交互）

lib/features/chat/providers/
└── chat_provider.dart             # 新增: generateGraph() 方法

lib/features/insights/
└── insights_page.dart             # 修改: 「查看思维图谱」按钮变为可用
```

---

### Task 1: 创建图谱数据模型

**Files:**
- Modify: `lib/core/models/chat_models.dart`

**说明：** 在现有 `chat_models.dart` 末尾添加 `GraphNode`、`GraphEdge`、`ConversationGraph` 三个类。

**Step 1: 添加数据模型**

```dart
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
}

/// 图谱连线 — 两个节点之间的关系
///
/// [source] [target] 是节点 id，[label] 是关系描述（如"推导出"、"包含"）。
/// [strength] 关系强度（影响连线粗细和布局吸引力）。
class GraphEdge {
  final String source; // 节点 id
  final String target; // 节点 id
  final String label; // 关系标签
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
        return value.map((e) => GraphNode.fromJson(e as Map<String, dynamic>)).toList();
      }
      return [];
    }
    List<GraphEdge> parseEdges(dynamic value) {
      if (value is List) {
        return value.map((e) => GraphEdge.fromJson(e as Map<String, dynamic>)).toList();
      }
      return [];
    }
    return ConversationGraph(
      nodes: parseNodes(json['nodes']),
      edges: parseEdges(json['edges']),
    );
  }

  bool get isEmpty => nodes.isEmpty;
  int get nodeCount => nodes.length;
  int get edgeCount => edges.length;
}
```

**Step 2: 运行静态分析**

Run: `flutter analyze lib/core/models/chat_models.dart`
Expected: No issues

**Step 3: 提交**

```bash
git add lib/core/models/chat_models.dart
git commit -m "feat(day6): add ConversationGraph, GraphNode, GraphEdge models"
```

---

### Task 2: 创建 GraphService（LLM 图谱生成）

**Files:**
- Create: `lib/features/mindmap/engine/graph_service.dart`

**说明：** 复用 InsightService 模式——通过 `LlamaService.engine` 创建独立 `EngineChat`，发送图谱生成 Prompt，解析 JSON 输出，三层回退。

**Step 1: 创建目录并实现 GraphService**

```bash
mkdir -p lib/features/mindmap/engine lib/features/mindmap/layout lib/features/mindmap/widgets
```

```dart
// lib/features/mindmap/engine/graph_service.dart
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide ChatMessage;

import 'package:socratic_ai/core/engine/llama_service.dart';
import 'package:socratic_ai/core/models/chat_models.dart';

/// 思维图谱生成服务
///
/// 接收完整对话历史，调用 LLM 提取结构化图谱数据（节点 + 连线）。
/// 复用 [InsightService] 的模式：独立 EngineChat → JSON 输出 → 三层回退解析。
class GraphService {
  final LlamaService _llm;

  GraphService(this._llm);

  // ================================================================
  // 系统提示词
  // ================================================================

  static const _systemPrompt =
      '你是一位知识图谱分析师。请分析以下对话，提取其中的关键概念和它们之间的关系。\n'
      '\n'
      '要求：\n'
      '1. 从对话中提取 4-8 个关键概念作为节点\n'
      '2. 节点 type 为以下之一：\n'
      '   - "topic"：对话话题\n'
      '   - "insight"：用户的核心认知/洞察\n'
      '   - "value"：用户的底层价值观\n'
      '   - "action"：用户提及的行动或决策\n'
      '   - "contradiction"：用户的认知矛盾\n'
      '3. weight 值 0-1（topic 和核心 insight 给 1.0，次要节点给 0.5）\n'
      '4. 节点之间如果有明确关联（因果、包含、对比、矛盾），用 edge 连接\n'
      '5. edge 的 label 用 2-4 字简要描述关系（如"导致"、"包含"、"矛盾"）\n'
      '6. 严格只输出 JSON，不要输出任何解释性文字\n'
      '\n'
      '输出格式：\n'
      '{"nodes":[{"id":"n1","label":"职业转型","type":"topic","weight":1.0},'
      '{"id":"n2","label":"害怕失败","type":"insight","weight":1.0}],'
      '"edges":[{"source":"n1","target":"n2","label":"核心矛盾","strength":0.9}]}';

  // ================================================================
  // 公开接口
  // ================================================================

  /// 生成对话思维图谱
  ///
  /// [topic] 对话话题，[conversation] 完整消息列表。
  /// 模型未加载时返回空图谱（前端展示空状态提示）。
  Future<ConversationGraph> generate(
    String topic,
    List<ChatMessage> conversation,
  ) async {
    final engine = _llm.engine;
    if (engine == null) {
      debugPrint('[GraphService] 模型未加载，跳过图谱生成');
      return const ConversationGraph();
    }

    final conversationText = _buildConversationText(topic, conversation);
    debugPrint('[GraphService] 对话长度: ${conversationText.length} 字');

    try {
      final chat = await engine.createChat();
      try {
        chat.addSystem(_systemPrompt);
        chat.addUser(conversationText);

        final buffer = StringBuffer();
        await for (final event in chat.generate(
          sampler: const SamplerParams(
            temperature: 0.3,
            topP: 0.8,
            repeatPenalty: 1.1,
          ),
          maxTokens: 512, // 图谱 JSON 比洞察大，给更多 token
        )) {
          if (event is TokenEvent) {
            buffer.write(event.text);
          }
        }

        final rawResponse = buffer.toString().trim();
        debugPrint('[GraphService] 原始回复: $rawResponse');
        return _parseResponse(rawResponse);
      } finally {
        chat.dispose();
      }
    } catch (e, stack) {
      debugPrint('[GraphService] 图谱生成失败: $e');
      debugPrintStack(stackTrace: stack);
      return const ConversationGraph();
    }
  }

  // ================================================================
  // 私有
  // ================================================================

  String _buildConversationText(String topic, List<ChatMessage> conversation) {
    final buffer = StringBuffer();
    buffer.writeln('话题：$topic\n');
    for (final msg in conversation) {
      final role = msg.role == MessageRole.ai ? 'AI' : '用户';
      buffer.writeln('$role：${msg.content}');
    }
    return buffer.toString();
  }

  /// 三层回退 JSON 解析
  ConversationGraph _parseResponse(String raw) {
    // 层 1：直接 JSON 解析
    try {
      return ConversationGraph.fromJson(jsonDecode(raw.trim()) as Map<String, dynamic>);
    } catch (_) {}

    // 层 2：提取 markdown 代码块
    final codeBlock = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```');
    final codeMatch = codeBlock.firstMatch(raw);
    if (codeMatch != null) {
      try {
        return ConversationGraph.fromJson(
          jsonDecode(codeMatch.group(1)!.trim()) as Map<String, dynamic>,
        );
      } catch (_) {}
    }

    // 层 3：提取最外层 JSON 对象
    final jsonObj = RegExp(r'\{[\s\S]*\}');
    final jsonMatch = jsonObj.firstMatch(raw);
    if (jsonMatch != null) {
      try {
        return ConversationGraph.fromJson(
          jsonDecode(jsonMatch.group(0)!) as Map<String, dynamic>,
        );
      } catch (_) {}
    }

    // 兜底：空图谱，UI 展示「图谱生成失败」
    debugPrint('[GraphService] JSON 解析全部失败');
    return const ConversationGraph();
  }
}
```

**Step 2: 验证编译**

Run: `flutter analyze lib/features/mindmap/engine/graph_service.dart`
Expected: No issues

**Step 3: 提交**

```bash
git add lib/features/mindmap/engine/graph_service.dart
git commit -m "feat(day6): add GraphService with LLM-powered conversation graph generation"
```

---

### Task 3: 实现 Force-Directed 布局算法

**Files:**
- Create: `lib/features/mindmap/layout/force_directed.dart`

**说明：** 纯 Dart 实现，无需外部依赖。算法核心：
1. 每个节点受两种力：**斥力**（节点之间互相排斥）+ **吸引力**（连线两端互相吸引）
2. 迭代 N 次（默认 100），每次计算合力 → 更新位置 + 阻尼衰减
3. 最终把坐标系归一化到 [0.15, 0.85] 范围内居中

**Step 1: 实现布局算法**

```dart
// lib/features/mindmap/layout/force_directed.dart
import 'dart:math';
import 'package:socratic_ai/core/models/chat_models.dart';

/// Force-directed 图谱布局算法
///
/// 纯 Dart 实现，不依赖外部库。
/// 接收 [ConversationGraph]，计算每个节点的 (x, y) 坐标和 radius。
///
/// 使用方式：
/// ```dart
/// final layout = ForceDirectedLayout(graph: graph, width: 400, height: 600);
/// layout.run(iterations: 100);
/// ```
class ForceDirectedLayout {
  final List<GraphNode> nodes;
  final List<GraphEdge> edges;
  final double width;
  final double height;

  // 算法参数
  static const double _repulsionStrength = 200.0; // 斥力强度
  static const double _attractionStrength = 0.01;  // 吸引力强度
  static const double _damping = 0.85;              // 速度阻尼（越高越快收敛）
  static const double _minVelocity = 0.01;          // 停止阈值
  static const int _maxIterations = 150;            // 最大迭代次数

  ForceDirectedLayout({
    required this.nodes,
    required this.edges,
    required this.width,
    required this.height,
  });

  /// 运行布局算法，计算所有节点的坐标
  void run({int? iterations}) {
    final maxIter = iterations ?? _maxIterations;
    final rng = Random(42); // 固定种子，保证可复现

    // 1. 初始化：随机位置 + 零速度
    for (final node in nodes) {
      node.x = rng.nextDouble() * 0.6 + 0.2; // 0.2-0.8 范围
      node.y = rng.nextDouble() * 0.6 + 0.2;
      node.vx = 0;
      node.vy = 0;
    }

    // 2. 迭代
    for (int iter = 0; iter < maxIter; iter++) {
      double totalEnergy = 0;

      // 计算每个节点的受力
      for (final node in nodes) {
        double fx = 0, fy = 0;

        // 斥力：所有其他节点对本节点的排斥
        for (final other in nodes) {
          if (other == node) continue;
          final dx = node.x! - other.x!;
          final dy = node.y! - other.y!;
          final dist = max(sqrt(dx * dx + dy * dy), 0.01);
          final force = _repulsionStrength / (dist * dist);
          fx += (dx / dist) * force;
          fy += (dy / dist) * force;
        }

        // 吸引力：连线相连的节点之间互相吸引
        for (final edge in edges) {
          GraphNode? target;
          if (edge.source == node.id) {
            target = nodes.cast<GraphNode?>().firstWhere((n) => n.id == edge.target, orElse: () => null);
          } else if (edge.target == node.id) {
            target = nodes.cast<GraphNode?>().firstWhere((n) => n.id == edge.source, orElse: () => null);
          }
          if (target == null) continue;

          final dx = target.x! - node.x!;
          final dy = target.y! - node.y!;
          final dist = sqrt(dx * dx + dy * dy);
          final force = dist * _attractionStrength * edge.strength;
          fx += dx * force;
          fy += dy * force;
        }

        // 中心引力：所有节点轻微向中心靠拢
        fx += (0.5 - node.x!) * 0.01;
        fy += (0.5 - node.y!) * 0.01;

        // 边界约束力
        const margin = 0.1;
        if (node.x! < margin) fx += (margin - node.x!) * 0.5;
        if (node.x! > 1.0 - margin) fx -= (node.x! - (1.0 - margin)) * 0.5;
        if (node.y! < margin) fy += (margin - node.y!) * 0.5;
        if (node.y! > 1.0 - margin) fy -= (node.y! - (1.0 - margin)) * 0.5;

        // 更新速度
        node.vx = (node.vx! + fx) * _damping;
        node.vy = (node.vy! + fy) * _damping;

        totalEnergy += node.vx!.abs() + node.vy!.abs();
      }

      // 应用速度
      for (final node in nodes) {
        node.x = node.x! + node.vx!;
        node.y = node.y! + node.vy!;
      }

      // 提前收敛
      if (totalEnergy < _minVelocity * nodes.length) break;
    }

    // 3. 计算半径（与 weight 成正比）
    const minRadius = 28.0;
    const maxRadius = 48.0;
    for (final node in nodes) {
      node.radius = minRadius + (maxRadius - minRadius) * node.weight;
    }
  }
}
```

**Step 2: 验证编译**

Run: `flutter analyze lib/features/mindmap/layout/force_directed.dart`
Expected: No issues

**Step 3: 提交**

```bash
git add lib/features/mindmap/layout/force_directed.dart
git commit -m "feat(day6): add force-directed graph layout algorithm"
```

---

### Task 4: 实现 GraphPainter（CustomPainter 渲染）

**Files:**
- Create: `lib/features/mindmap/widgets/graph_painter.dart`

**说明：** 用 Canvas API 绘制节点（圆形 + 标签）和连线（贝塞尔曲线 + 箭头）。节点颜色按 type 分类，大小按 weight 变化。

**Step 1: 实现 GraphPainter**

```dart
// lib/features/mindmap/widgets/graph_painter.dart
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/theme.dart';

/// 思维图谱 CustomPainter
///
/// 绘制节点（圆形 + 标签）和连线（直线 + 关系标签）。
/// 节点颜色按 type 分类，线宽按 strength 变化。
class GraphPainter extends CustomPainter {
  final List<GraphNode> nodes;
  final List<GraphEdge> edges;
  final GraphNode? selectedNode;
  final double scale; // 当前缩放比例

  GraphPainter({
    required this.nodes,
    required this.edges,
    this.selectedNode,
    this.scale = 1.0,
  });

  // ================================================================
  // 节点颜色映射
  // ================================================================

  static Color _nodeColor(String type) {
    switch (type) {
      case 'topic':
        return AppTheme.primary;          // 鼠尾草绿
      case 'insight':
        return const Color(0xFF5B8D8D);  // 深青
      case 'value':
        return AppTheme.secondary;        // 暖棕
      case 'action':
        return AppTheme.accent;           // 暖金
      case 'contradiction':
        return const Color(0xFFD4735B);  // 暖红
      default:
        return AppTheme.primary;
    }
  }

  static Color _nodeColorLight(String type) {
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

  // ================================================================
  // 分类名称映射
  // ================================================================

  static String _typeLabel(String type) {
    switch (type) {
      case 'topic': return '话题';
      case 'insight': return '洞察';
      case 'value': return '价值观';
      case 'action': return '行动';
      case 'contradiction': return '矛盾';
      default: return '';
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    _drawEdges(canvas, size);
    _drawNodes(canvas, size);
  }

  // ----------------------------------------------------------------
  // 连线
  // ----------------------------------------------------------------

  void _drawEdges(Canvas canvas, Size size) {
    for (final edge in edges) {
      final source = _findNode(edge.source);
      final target = _findNode(edge.target);
      if (source == null || target == null) continue;
      if (source.x == null || source.y == null || target.x == null || target.y == null) continue;

      final x1 = source.x! * size.width;
      final y1 = source.y! * size.height;
      final x2 = target.x! * size.width;
      final y2 = target.y! * size.height;

      final paint = Paint()
        ..color = const Color(0xFFD0C8C0)
        ..strokeWidth = 1.0 + edge.strength * 2.5
        ..style = PaintingStyle.stroke;

      canvas.drawLine(Offset(x1, y1), Offset(x2, y2), paint);

      // 关系标签（中点位置）
      if (edge.label.isNotEmpty) {
        final midX = (x1 + x2) / 2;
        final midY = (y1 + y2) / 2;
        final tp = TextPainter(
          text: TextSpan(
            text: edge.label,
            style: TextStyle(
              fontSize: 10 / scale,
              color: AppTheme.textSecondary,
              backgroundColor: AppTheme.background.withValues(alpha: 0.8),
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(midX - tp.width / 2, midY - tp.height / 2));
      }
    }
  }

  // ----------------------------------------------------------------
  // 节点
  // ----------------------------------------------------------------

  void _drawNodes(Canvas canvas, Size size) {
    for (final node in nodes) {
      if (node.x == null || node.y == null) continue;

      final cx = node.x! * size.width;
      final cy = node.y! * size.height;
      final r = (node.radius ?? 32) * scale;

      final isSelected = node.id == selectedNode?.id;
      final color = _nodeColor(node.type);
      final lightColor = _nodeColorLight(node.type);

      // 圆形背景
      final fillPaint = Paint()
        ..color = isSelected ? color : lightColor
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(cx, cy), r, fillPaint);

      // 圆形边框
      final strokePaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = isSelected ? 2.5 : 1.5;
      canvas.drawCircle(Offset(cx, cy), r, strokePaint);

      // 节点标签（限制两行）
      final labelMaxWidth = r * 1.6;
      final tp = TextPainter(
        text: TextSpan(
          text: node.label,
          style: TextStyle(
            fontSize: (isSelected ? 13 : 12) * scale,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
            color: isSelected ? color : AppTheme.textPrimary,
            height: 1.3,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 2,
        ellipsis: '...',
      )..layout(maxWidth: labelMaxWidth);
      tp.paint(canvas, Offset(cx - tp.width / 2, cy - tp.height / 2));

      // 分类小标签（节点下方）
      final tag = _typeLabel(node.type);
      final tagPainter = TextPainter(
        text: TextSpan(
          text: tag,
          style: TextStyle(
            fontSize: 9 * scale,
            color: AppTheme.textSecondary,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tagPainter.paint(
        canvas,
        Offset(cx - tagPainter.width / 2, cy + r + 4 * scale),
      );

      // 选中态：轻微光晕
      if (isSelected) {
        final glowPaint = Paint()
          ..color = color.withValues(alpha: 0.15)
          ..style = PaintingStyle.fill
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
        canvas.drawCircle(Offset(cx, cy), r + 6, glowPaint);
      }
    }
  }

  GraphNode? _findNode(String id) {
    try {
      return nodes.firstWhere((n) => n.id == id);
    } catch (_) {
      return null;
    }
  }

  // ----------------------------------------------------------------
  // 命中检测（供手势交互使用）
  // ----------------------------------------------------------------

  /// 返回给定画布坐标下的节点（null = 没命中）
  GraphNode? hitTest(Offset position, Size size) {
    for (final node in nodes) {
      if (node.x == null || node.y == null) continue;
      final cx = node.x! * size.width;
      final cy = node.y! * size.height;
      final r = (node.radius ?? 32) * scale;
      final dx = position.dx - cx;
      final dy = position.dy - cy;
      if (dx * dx + dy * dy <= r * r) return node;
    }
    return null;
  }

  @override
  bool shouldRepaint(covariant GraphPainter oldDelegate) {
    return oldDelegate.scale != scale ||
        oldDelegate.selectedNode?.id != selectedNode?.id ||
        oldDelegate.nodes != nodes;
  }
}
```

**Step 2: 验证编译**

Run: `flutter analyze lib/features/mindmap/widgets/graph_painter.dart`
Expected: No issues

**Step 3: 提交**

```bash
git add lib/features/mindmap/widgets/graph_painter.dart
git commit -m "feat(day6): add GraphPainter with node/edge rendering and hit testing"
```

---

### Task 5: 实现节点详情弹窗

**Files:**
- Create: `lib/features/mindmap/widgets/node_detail_sheet.dart`

**说明：** 点击节点后展示底部弹窗，显示节点详情和关联节点。

**Step 1: 实现 NodeDetailSheet**

```dart
// lib/features/mindmap/widgets/node_detail_sheet.dart
import 'package:flutter/material.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/theme.dart';

/// 节点详情底部弹窗
///
/// 显示选中节点的详细信息：分类、标签、关联节点。
class NodeDetailSheet extends StatelessWidget {
  final GraphNode node;
  final List<GraphEdge> edges;
  final List<GraphNode> allNodes;

  const NodeDetailSheet({
    super.key,
    required this.node,
    required this.edges,
    required this.allNodes,
  });

  @override
  Widget build(BuildContext context) {
    final relatedEdges = edges.where(
      (e) => e.source == node.id || e.target == node.id,
    ).toList();

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 拖拽指示条
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFD0C8C0),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          // 节点标签
          Text(
            node.label,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          // 分类
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: _typeColor(node.type).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              _typeLabel(node.type),
              style: TextStyle(
                fontSize: 12,
                color: _typeColor(node.type),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          // 关联节点
          if (relatedEdges.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              '关联概念',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            ...relatedEdges.map((edge) {
              final otherId = edge.source == node.id ? edge.target : edge.source;
              final otherNode = allNodes.cast<GraphNode?>().firstWhere(
                    (n) => n.id == otherId,
                    orElse: () => null,
                  );
              if (otherNode == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Icon(Icons.arrow_forward, size: 14, color: _typeColor(otherNode.type)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        otherNode.label,
                        style: const TextStyle(
                          fontSize: 14,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                    ),
                    if (edge.label.isNotEmpty)
                      Text(
                        '(${edge.label})',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Color _typeColor(String type) {
    switch (type) {
      case 'topic': return AppTheme.primary;
      case 'insight': return const Color(0xFF5B8D8D);
      case 'value': return AppTheme.secondary;
      case 'action': return AppTheme.accent;
      case 'contradiction': return const Color(0xFFD4735B);
      default: return AppTheme.primary;
    }
  }

  String _typeLabel(String type) {
    switch (type) {
      case 'topic': return '话题';
      case 'insight': return '洞察';
      case 'value': return '价值观';
      case 'action': return '行动';
      case 'contradiction': return '矛盾';
      default: return '';
    }
  }
}
```

**Step 2: 验证编译**

Run: `flutter analyze lib/features/mindmap/widgets/node_detail_sheet.dart`
Expected: No issues

**Step 3: 提交**

```bash
git add lib/features/mindmap/widgets/node_detail_sheet.dart
git commit -m "feat(day6): add node detail bottom sheet widget"
```

---

### Task 6: 实现 MindMapPage（图谱页面 + 手势交互）

**Files:**
- Create: `lib/features/mindmap/mindmap_page.dart`

**说明：** 接收 `ConversationGraph`，运行 force-directed 布局，用 CustomPainter 渲染，支持拖拽节点、双指缩放、单指平移、点击展开详情。

**Step 1: 实现 MindMapPage**

```dart
// lib/features/mindmap/mindmap_page.dart
import 'package:flutter/material.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/mindmap/layout/force_directed.dart';
import 'package:socratic_ai/features/mindmap/widgets/graph_painter.dart';
import 'package:socratic_ai/features/mindmap/widgets/node_detail_sheet.dart';

/// 思维图谱页面
///
/// 展示一次对话的知识图谱可视化。
/// 交互：拖拽节点 / 双指缩放 / 单指平移 / 点击查看详情。
class MindMapPage extends StatefulWidget {
  final ConversationGraph graph;
  final String topic;

  const MindMapPage({super.key, required this.graph, required this.topic});

  @override
  State<MindMapPage> createState() => _MindMapPageState();
}

class _MindMapPageState extends State<MindMapPage> {
  // 交互状态
  double _scale = 0.7;          // 初始缩放（缩小一点看到全貌）
  Offset _offset = Offset.zero; // 平移偏移
  GraphNode? _selectedNode;
  GraphNode? _draggedNode;      // 正在拖拽的节点
  double _baseScale = 0.7;      // 手势开始时的基础缩放
  Offset _baseOffset = Offset.zero;

  // 布局结果
  late final List<GraphNode> _nodes;
  late final List<GraphEdge> _edges;

  @override
  void initState() {
    super.initState();
    // 深拷贝节点（避免布局影响原始数据）
    _nodes = widget.graph.nodes.map((n) => GraphNode(
      id: n.id,
      label: n.label,
      type: n.type,
      weight: n.weight,
    )).toList();
    _edges = widget.graph.edges;

    // 延迟运行布局（等拿到画布尺寸）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runLayout();
    });
  }

  void _runLayout() {
    final size = MediaQuery.of(context).size;
    final layout = ForceDirectedLayout(
      nodes: _nodes,
      edges: _edges,
      width: size.width,
      height: size.height - kToolbarHeight - MediaQuery.of(context).padding.top,
    );
    layout.run();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isEmpty = _nodes.isEmpty;

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        title: Text(widget.topic),
      ),
      body: isEmpty ? _buildEmptyState() : _buildGraph(),
    );
  }

  // ================================================================
  // 图谱交互
  // ================================================================

  Widget _buildGraph() {
    return GestureDetector(
      onScaleStart: _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      onTapUp: _onTapUp,
      child: ClipRect(
        child: CustomPaint(
          painter: GraphPainter(
            nodes: _nodes,
            edges: _edges,
            selectedNode: _selectedNode,
            scale: _scale,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }

  void _onScaleStart(ScaleStartDetails details) {
    _baseScale = _scale;
    _baseOffset = _offset;

    // 检测是否拖拽节点
    final size = MediaQuery.of(context).size;
    final localPos = details.localFocalPoint;
    final graphPainter = GraphPainter(
      nodes: _nodes,
      edges: _edges,
      scale: _scale,
    );
    // 将画布坐标转换为布局坐标
    final transformedPos = Offset(
      (localPos.dx - _offset.dx) / _scale,
      (localPos.dy - _offset.dy) / _scale,
    );
    _draggedNode = graphPainter.hitTest(transformedPos, size);
    if (_draggedNode != null) {
      _selectedNode = _draggedNode;
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    setState(() {
      if (details.pointerCount >= 2 || _draggedNode == null) {
        // 双指缩放 + 平移
        _scale = (_baseScale * details.scale).clamp(0.3, 2.5);
        _offset = _baseOffset + details.focalPoint - details.localFocalPoint;
      } else if (_draggedNode != null) {
        // 单指拖拽节点
        final size = MediaQuery.of(context).size;
        _draggedNode!.x = (_draggedNode!.x ?? 0) + details.focalPointDelta.dx / (_scale * size.width);
        _draggedNode!.y = (_draggedNode!.y ?? 0) + details.focalPointDelta.dy / (_scale * size.height);
        // 限制在画布内
        _draggedNode!.x = _draggedNode!.x!.clamp(0.05, 0.95);
        _draggedNode!.y = _draggedNode!.y!.clamp(0.05, 0.95);
      }
    });
  }

  void _onTapUp(TapUpDetails details) {
    final size = MediaQuery.of(context).size;
    final graphPainter = GraphPainter(
      nodes: _nodes,
      edges: _edges,
      scale: _scale,
    );
    // 将画布坐标转换为布局坐标
    final transformedPos = Offset(
      (details.localPosition.dx - _offset.dx) / _scale,
      (details.localPosition.dy - _offset.dy) / _scale,
    );
    final hitNode = graphPainter.hitTest(transformedPos, size);

    if (hitNode != null) {
      setState(() => _selectedNode = hitNode);
      _showDetailSheet(hitNode);
    } else {
      setState(() => _selectedNode = null);
    }
  }

  void _showDetailSheet(GraphNode node) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => NodeDetailSheet(
        node: node,
        edges: _edges,
        allNodes: _nodes,
      ),
    );
  }

  // ================================================================
  // 空状态
  // ================================================================

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.account_tree_outlined, size: 48, color: AppTheme.textSecondary),
          const SizedBox(height: 16),
          const Text('无法生成思维图谱', style: TextStyle(fontSize: 16, color: AppTheme.textPrimary)),
          const SizedBox(height: 8),
          const Text(
            '请确保模型已加载并重试',
            style: TextStyle(color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('返回'),
          ),
        ],
      ),
    );
  }
}
```

**Step 2: 验证编译**

Run: `flutter analyze lib/features/mindmap/mindmap_page.dart`
Expected: No issues

**Step 3: 提交**

```bash
git add lib/features/mindmap/mindmap_page.dart
git commit -m "feat(day6): add MindMapPage with gesture-based graph interaction"
```

---

### Task 7: ChatProvider 新增图谱生成方法

**Files:**
- Modify: `lib/features/chat/providers/chat_provider.dart`

**说明：** 在 ChatProvider 中新增 `generateGraph()` 方法，复用 `SocraticPrompter.llmService`，通过 `GraphService` 生成图谱。

**Step 1: 添加 import 和方法**

在文件顶部 import 区域添加：

```dart
import '../../mindmap/engine/graph_service.dart';
```

在 `endConversation()` 方法之后添加：

```dart
  /// 生成对话思维图谱
  ///
  /// 通过 GraphService 调用 LLM 分析完整对话历史。
  /// 引擎未就绪时返回空图谱。
  Future<ConversationGraph> generateGraph() async {
    final engine = _engine;
    if (engine == null || engine is! SocraticPrompter) {
      return const ConversationGraph();
    }

    try {
      final service = GraphService(engine.llmService);
      return await service.generate(topic, messages);
    } catch (e) {
      debugPrint('[ChatProvider] 图谱生成失败: $e');
      return const ConversationGraph();
    }
  }
```

**Step 2: 验证编译**

Run: `flutter analyze lib/features/chat/providers/chat_provider.dart`
Expected: No issues

**Step 3: 提交**

```bash
git add lib/features/chat/providers/chat_provider.dart
git commit -m "feat(day6): add generateGraph() to ChatProvider"
```

---

### Task 8: 启用 InsightsPage 的「查看思维图谱」按钮

**Files:**
- Modify: `lib/features/insights/insights_page.dart`

**说明：** 将「查看思维图谱」按钮从灰色（`onPressed: null`）变为可用，点击后调用 `ChatProvider.generateGraph()` 或从本地传过来的方式生成图谱并跳转。

**设计决策**：InsightsPage 已经接收 `InsightResult`，但图谱生成需要 `ChatProvider`（因为需要 `LlamaService`）。两种方案：
- **方案 A**：InsightsPage 通过构造函数接收一个生成回调
- **方案 B**：在进入 InsightsPage 之前（ChatPage._endConversation）就生成图谱，同时传给 InsightsPage

**选择方案 B**——图谱生成耗时 2-4s（LLM 推理），在对话结束时和洞察总结一起异步生成。InsightsPage 接收已生成好的 `ConversationGraph`。

**Step 1: 修改 InsightsPage 构造函数**

```dart
// 在 InsightResult insight 下面添加:
  final ConversationGraph? graph;

  const InsightsPage({
    super.key,
    required this.insight,
    required this.topic,
    this.fromHistory = false,
    this.graph,
  });
```

**Step 2: 修改「查看思维图谱」按钮**

将 `onPressed: null` 改为：

```dart
onPressed: widget.graph != null && widget.graph!.isNotEmpty
    ? () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => MindMapPage(
              graph: widget.graph!,
              topic: widget.topic,
            ),
          ),
        );
      }
    : null,
```

**Step 3: 更新 ChatPage._endConversation**

在 `lib/features/chat/chat_page.dart` 中，修改 `_endConversation` 逻辑：

```dart
  Future<void> _endConversation(BuildContext context, ChatProvider chatProvider) async {
    // 显示 loading
    showDialog(/* ... 同上 ... */);

    // 并行生成洞察和图谱
    InsightResult insight;
    ConversationGraph graph;
    try {
      final results = await Future.wait([
        chatProvider.endConversation(),
        chatProvider.generateGraph(),
      ]);
      insight = results[0] as InsightResult;
      graph = results[1] as ConversationGraph;
    } catch (e) {
      insight = const InsightResult(
        coreInsights: ['对话分析完成'],
        underlyingValues: [],
        contradictionsFound: [],
      );
      graph = const ConversationGraph();
    }

    if (!context.mounted) return;
    Navigator.pop(context); // 关闭 loading
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => InsightsPage(
          insight: insight,
          topic: widget.topic,
          graph: graph.isNotEmpty ? graph : null,
        ),
      ),
    );
  }
```

**Step 4: 验证编译**

Run: `flutter analyze lib/features/insights/insights_page.dart lib/features/chat/chat_page.dart`
Expected: No issues

**Step 5: 提交**

```bash
git add lib/features/insights/insights_page.dart lib/features/chat/chat_page.dart
git commit -m "feat(day6): wire up mind map button in InsightsPage, generate graph alongside insight"
```

---

### Task 9: 单元测试

**Files:**
- Create: `test/core/models/chat_models_graph_test.dart`
- Create: `test/features/mindmap/layout/force_directed_test.dart`

**Step 1: 数据模型序列化测试**

```dart
// test/core/models/chat_models_graph_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:socratic_ai/core/models/chat_models.dart';

void main() {
  group('ConversationGraph JSON 序列化', () {
    test('fromJson 正确解析完整图谱', () {
      final json = {
        'nodes': [
          {'id': 'n1', 'label': '职业转型', 'type': 'topic', 'weight': 1.0},
          {'id': 'n2', 'label': '害怕失败', 'type': 'insight', 'weight': 0.8},
        ],
        'edges': [
          {'source': 'n1', 'target': 'n2', 'label': '核心矛盾', 'strength': 0.9},
        ],
      };

      final graph = ConversationGraph.fromJson(json);

      expect(graph.nodes.length, 2);
      expect(graph.edges.length, 1);
      expect(graph.nodes[0].label, '职业转型');
      expect(graph.nodes[0].type, 'topic');
      expect(graph.edges[0].label, '核心矛盾');
    });

    test('fromJson 容错：空 JSON', () {
      final graph = ConversationGraph.fromJson({});
      expect(graph.nodes, isEmpty);
      expect(graph.edges, isEmpty);
    });

    test('fromJson 容错：缺少字段', () {
      final json = {
        'nodes': [
          {'id': 'n1'}, // 缺 label, type, weight
        ],
      };

      final graph = ConversationGraph.fromJson(json);
      expect(graph.nodes.length, 1);
      expect(graph.nodes[0].label, '');
      expect(graph.nodes[0].type, 'insight'); // 默认值
      expect(graph.nodes[0].weight, 0.5);      // 默认值
    });
  });

  group('GraphNode JSON 序列化', () {
    test('toJson/fromJson 往返', () {
      final node = GraphNode(
        id: 'n1',
        label: '测试标签',
        type: 'insight',
        weight: 0.75,
      );

      final restored = GraphNode.fromJson(node.toJson());
      expect(restored.id, 'n1');
      expect(restored.label, '测试标签');
      expect(restored.type, 'insight');
      expect(restored.weight, 0.75);
    });
  });
}
```

**Step 2: 布局算法测试**

```dart
// test/features/mindmap/layout/force_directed_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/features/mindmap/layout/force_directed.dart';

void main() {
  group('ForceDirectedLayout', () {
    test('布局后所有节点都有坐标', () {
      final nodes = [
        GraphNode(id: 'a', label: 'A', type: 'topic', weight: 1.0),
        GraphNode(id: 'b', label: 'B', type: 'insight', weight: 0.8),
        GraphNode(id: 'c', label: 'C', type: 'value', weight: 0.6),
      ];
      final edges = [
        GraphEdge(source: 'a', target: 'b'),
        GraphEdge(source: 'b', target: 'c'),
      ];

      final layout = ForceDirectedLayout(
        nodes: nodes,
        edges: edges,
        width: 400,
        height: 600,
      );
      layout.run(iterations: 50);

      for (final node in nodes) {
        expect(node.x, isNotNull);
        expect(node.y, isNotNull);
        expect(node.radius, isNotNull);
        expect(node.x!, inInclusiveRange(0.0, 1.0));
        expect(node.y!, inInclusiveRange(0.0, 1.0));
      }
    });

    test('空图谱不崩溃', () {
      final layout = ForceDirectedLayout(
        nodes: [],
        edges: [],
        width: 400,
        height: 600,
      );
      layout.run(); // 不应该抛异常
    });

    test('节点半径与 weight 成正比', () {
      final nodes = [
        GraphNode(id: 'big', label: 'Big', type: 'topic', weight: 1.0),
        GraphNode(id: 'small', label: 'Small', type: 'insight', weight: 0.2),
      ];
      final layout = ForceDirectedLayout(
        nodes: nodes,
        edges: [],
        width: 400,
        height: 600,
      );
      layout.run();

      final bigNode = nodes[0];
      final smallNode = nodes[1];
      expect(bigNode.radius!, greaterThan(smallNode.radius!));
    });
  });
}
```

**Step 3: 运行测试**

```bash
flutter test test/core/models/chat_models_graph_test.dart test/features/mindmap/layout/force_directed_test.dart
```

Expected: All tests pass

**Step 4: 提交**

```bash
git add test/core/models/chat_models_graph_test.dart test/features/mindmap/layout/force_directed_test.dart
git commit -m "test(day6): add tests for graph models and force-directed layout"
```

---

### Task 10: 全链路验证

**Step 1: 静态分析**

Run: `flutter analyze lib/ test/`
Expected: No errors in lib/

**Step 2: 全部测试**

Run: `flutter test`
Expected: All tests pass

**Step 3: 手动验证场景**

启动 App → 选话题 → 对话 5+ 轮 → 点击「结束对话」：
- [ ] Loading 弹窗显示「正在生成洞察总结...」
- [ ] 弹窗消失后跳转 InsightsPage
- [ ] **「查看思维图谱」按钮可点击**（不再灰色）
- [ ] 点击 → 跳转 MindMapPage
- [ ] 图谱显示节点 + 连线（force-directed 布局）
- [ ] 双指缩放正常工作
- [ ] 单指平移正常工作
- [ ] 拖拽节点位置更新
- [ ] 点击节点弹出底部详情弹窗
- [ ] 弹窗显示节点标签、分类、关联节点

**Step 4: 收尾提交**

```bash
git commit --allow-empty -m "chore(day6): mark Day 6 mind map complete"
```

---

## 改动文件汇总

| 操作 | 文件 | 说明 |
|:--|------|------|
| 修改 | `lib/core/models/chat_models.dart` | 新增 GraphNode, GraphEdge, ConversationGraph |
| 新建 | `lib/features/mindmap/engine/graph_service.dart` | LLM 图谱生成（三层回退 JSON 解析） |
| 新建 | `lib/features/mindmap/layout/force_directed.dart` | Force-directed 布局算法 |
| 新建 | `lib/features/mindmap/widgets/graph_painter.dart` | CustomPainter 渲染 + 命中检测 |
| 新建 | `lib/features/mindmap/widgets/node_detail_sheet.dart` | 节点详情底部弹窗 |
| 新建 | `lib/features/mindmap/mindmap_page.dart` | 图谱页面 + 手势交互 |
| 修改 | `lib/features/chat/providers/chat_provider.dart` | 新增 generateGraph() 方法 |
| 修改 | `lib/features/insights/insights_page.dart` | 启用思维图谱按钮 + 接收 graph 参数 |
| 修改 | `lib/features/chat/chat_page.dart` | 并行生成洞察和图谱 |
| 新建 | `test/core/models/chat_models_graph_test.dart` | 图谱模型序列化测试 |
| 新建 | `test/features/mindmap/layout/force_directed_test.dart` | 布局算法测试 |

## 技术决策

| 决策 | 选项 | 选择 | 原因 |
|:--|------|:--:|------|
| 图谱生成 | LLM 端侧 / 规则引擎 | **LLM 端侧** | 复用 InsightService 模式，JSON 输出，LLM 理解对话语义 |
| 布局算法 | force-directed / dagre / 环形 | **force-directed 自实现** | 无需外部依赖；~100 行 Dart；交互自然 |
| 图谱生成时机 | 与洞察并行 / 独立触发 | **与洞察并行** | 一次 loading 等待两个结果；Future.wait 并发 |
| 图谱数据传递 | Provider / 构造函数 | **构造函数** | MindMapPage 只是一次性展示，不跨页面共享 |
| 手势交互 | InteractiveViewer / 手写 GestureDetector | **手写 GestureDetector** | 需要区分拖拽节点 vs 平移画布，InteractiveViewer 不支持这种混合交互 |
