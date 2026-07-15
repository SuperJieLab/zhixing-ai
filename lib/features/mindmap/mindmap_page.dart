import 'package:flutter/material.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/mindmap/layout/force_directed.dart';
import 'package:socratic_ai/features/mindmap/providers/mindmap_provider.dart';
import 'package:socratic_ai/features/mindmap/widgets/graph_painter.dart';
import 'package:socratic_ai/features/mindmap/widgets/node_detail_sheet.dart';

/// 思维图谱页面
///
/// 两种使用方式：
/// - 传入 [graph]（预生成）→ 直接渲染
/// - 传入 [messages] + [topic] → 页面内通过 MindMapProvider 生成
///
/// 交互：拖拽节点 / 双指缩放 / 单指平移 / 点击查看详情。
class MindMapPage extends StatefulWidget {
  /// 预生成的图谱（直接渲染模式）
  final ConversationGraph? graph;

  final String topic;

  /// 对话消息（生成模式，graph 为 null 时必传）
  final List<ChatMessage>? messages;

  /// 会话 ID（生成模式，用于持久化）
  final int? conversationId;

  /// DB 缓存的图谱（优先于 LLM 生成）
  final ConversationGraph? cachedGraph;

  const MindMapPage({
    super.key,
    this.graph,
    required this.topic,
    this.messages,
    this.conversationId,
    this.cachedGraph,
  });

  @override
  State<MindMapPage> createState() => _MindMapPageState();
}

class _MindMapPageState extends State<MindMapPage> {
  // ── 交互状态 ──
  double _scale = 1.0;
  Offset _offset = Offset.zero;
  GraphNode? _selectedNode;
  GraphNode? _draggedNode;
  double _baseScale = 1.0;

  // ── 布局 ──
  List<GraphNode> _nodes = [];
  List<GraphEdge> _edges = [];
  bool _layoutDone = false;

  // ── 画布实际尺寸（LayoutBuilder 提供，与 paint / 手势统一） ──
  Size? _canvasSize;

  // ── 生成状态 ──
  final MindMapProvider _provider = MindMapProvider();
  bool _isGenerating = false;

  @override
  void initState() {
    super.initState();

    final graph = widget.graph;
    if (graph != null && graph.isNotEmpty) {
      _initFromGraph(graph);
    } else if (widget.messages != null && widget.messages!.isNotEmpty) {
      _isGenerating = true;
      _provider.generateGraph(
        topic: widget.topic,
        messages: widget.messages!,
        conversationId: widget.conversationId,
        cachedGraph: widget.cachedGraph,
      ).then((_) {
        if (!mounted) return;
        final g = _provider.graph;
        if (g != null && g.isNotEmpty) {
          setState(() {
            _isGenerating = false;
            _initFromGraph(g);
          });
        } else {
          setState(() => _isGenerating = false);
        }
      });
    }
  }

  void _initFromGraph(ConversationGraph graph) {
    _nodes = graph.nodes
        .map((n) => GraphNode(
              id: n.id,
              label: n.label,
              type: n.type,
              weight: n.weight,
            ))
        .toList();
    _edges = graph.edges;
  }

  void _runLayout(Size size) {
    if (_layoutDone) return;
    _layoutDone = true;
    _canvasSize = size;
    final layout = ForceDirectedLayout(nodes: _nodes, edges: _edges);
    layout.run();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        title: Text(widget.topic),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    // 正在生成
    if (_isGenerating) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: AppTheme.primary),
            SizedBox(height: 20),
            Text('正在生成思维图谱...',
                style: TextStyle(color: AppTheme.textSecondary)),
          ],
        ),
      );
    }

    // 生成完成但无结果
    if (_nodes.isEmpty) {
      return _buildEmptyState();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        if (!_layoutDone) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _runLayout(constraints.biggest);
          });
        }
        return _buildGraph();
      },
    );
  }

  // ================================================================
  // 图谱 + 手势
  // ================================================================

  Widget _buildGraph() {
    final size = _canvasSize;
    if (size == null) return const SizedBox.shrink();

    return GestureDetector(
      onScaleStart: (d) => _onScaleStart(d, size),
      onScaleUpdate: (d) => _onScaleUpdate(d, size),
      onTapUp: (d) => _onTapUp(d, size),
      child: ClipRect(
        child: CustomPaint(
          painter: GraphPainter(
            nodes: _nodes,
            edges: _edges,
            selectedNode: _selectedNode,
            scale: _scale,
            offset: _offset,
          ),
          size: size,
        ),
      ),
    );
  }

  // ── 手势实现 ──

  Offset _screenToCanvas(Offset screenPos, Size canvasSize) {
    final cx = canvasSize.width / 2;
    final cy = canvasSize.height / 2;
    return Offset(
      cx + (screenPos.dx - cx - _offset.dx) / _scale,
      cy + (screenPos.dy - cy - _offset.dy) / _scale,
    );
  }

  void _onScaleStart(ScaleStartDetails details, Size canvasSize) {
    _baseScale = _scale;

    _draggedNode = _hitTestLayout(
      _screenToCanvas(details.localFocalPoint, canvasSize),
      canvasSize,
    );
    if (_draggedNode != null) {
      setState(() => _selectedNode = _draggedNode);
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details, Size canvasSize) {
    if (details.pointerCount >= 2 || _draggedNode == null) {
      final oldScale = _scale;
      final newScale = (_baseScale * details.scale).clamp(0.3, 2.5);

      Offset newOffset = _offset + details.focalPointDelta;

      if (newScale != oldScale) {
        final focal = details.localFocalPoint;
        final cx = canvasSize.width / 2;
        final cy = canvasSize.height / 2;
        final ratio = newScale / oldScale;
        newOffset = Offset(
          focal.dx - cx - ratio * (focal.dx - newOffset.dx - cx),
          focal.dy - cy - ratio * (focal.dy - newOffset.dy - cy),
        );
      }

      setState(() {
        _scale = newScale;
        _offset = newOffset;
      });
    } else {
      setState(() {
        final dx = details.focalPointDelta.dx / (_scale * canvasSize.width);
        final dy = details.focalPointDelta.dy / (_scale * canvasSize.height);
        _draggedNode!.x = ((_draggedNode!.x ?? 0.5) + dx).clamp(0.05, 0.95);
        _draggedNode!.y = ((_draggedNode!.y ?? 0.5) + dy).clamp(0.05, 0.95);
      });
    }
  }

  void _onTapUp(TapUpDetails details, Size canvasSize) {
    final hitNode = _hitTestLayout(
      _screenToCanvas(details.localPosition, canvasSize),
      canvasSize,
    );

    if (hitNode != null) {
      setState(() => _selectedNode = hitNode);
      _showDetailSheet(hitNode);
    } else {
      setState(() => _selectedNode = null);
    }
  }

  GraphNode? _hitTestLayout(Offset layoutPos, Size canvasSize) {
    for (final node in _nodes.reversed) {
      if (node.x == null || node.y == null || node.radius == null) continue;
      final cx = node.x! * canvasSize.width;
      final cy = node.y! * canvasSize.height;
      final r = node.radius!;
      final dx = layoutPos.dx - cx;
      final dy = layoutPos.dy - cy;
      if (dx * dx + dy * dy <= r * r) return node;
    }
    return null;
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
    final error = _provider.error;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.account_tree_outlined,
              size: 48, color: AppTheme.textSecondary),
          const SizedBox(height: 16),
          const Text('无法生成思维图谱',
              style: TextStyle(fontSize: 16, color: AppTheme.textPrimary)),
          const SizedBox(height: 8),
          Text(
            error ?? '请确保模型已加载并重试',
            style: const TextStyle(color: AppTheme.textSecondary),
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
