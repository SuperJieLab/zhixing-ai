import 'package:flutter/material.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/mindmap/layout/force_directed.dart';
import 'package:socratic_ai/features/mindmap/widgets/graph_painter.dart';
import 'package:socratic_ai/features/mindmap/widgets/node_detail_sheet.dart';

/// 思维图谱页面
///
/// 交互：拖拽节点 / 双指缩放 / 单指平移 / 点击查看详情。
class MindMapPage extends StatefulWidget {
  final ConversationGraph graph;
  final String topic;

  const MindMapPage({super.key, required this.graph, required this.topic});

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
  Offset _baseOffset = Offset.zero;

  // ── 布局 ──
  late final List<GraphNode> _nodes;
  late final List<GraphEdge> _edges;
  bool _layoutDone = false;

  // ── 画布实际尺寸（LayoutBuilder 提供，与 paint / 手势统一） ──
  Size? _canvasSize;

  @override
  void initState() {
    super.initState();
    _nodes = widget.graph.nodes
        .map((n) => GraphNode(
              id: n.id,
              label: n.label,
              type: n.type,
              weight: n.weight,
            ))
        .toList();
    _edges = widget.graph.edges;
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
      body: _nodes.isEmpty
          ? _buildEmptyState()
          : LayoutBuilder(
              builder: (context, constraints) {
                if (!_layoutDone) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _runLayout(constraints.biggest);
                  });
                }
                return _buildGraph();
              },
            ),
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

  void _onScaleStart(ScaleStartDetails details, Size canvasSize) {
    _baseScale = _scale;
    _baseOffset = _offset;

    // 触摸点 → 布局坐标系
    final lx = (details.localFocalPoint.dx - _offset.dx) / _scale;
    final ly = (details.localFocalPoint.dy - _offset.dy) / _scale;

    _draggedNode = _hitTestLayout(Offset(lx, ly), canvasSize);
    if (_draggedNode != null) {
      setState(() => _selectedNode = _draggedNode);
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details, Size canvasSize) {
    setState(() {
      if (details.pointerCount >= 2 || _draggedNode == null) {
        // 双指缩放 + 平移
        _scale = (_baseScale * details.scale).clamp(0.3, 2.5);
        _offset = _baseOffset + details.focalPoint - details.localFocalPoint;
      } else {
        // 单指拖拽节点（布局坐标系内）
        _draggedNode!.x = (_draggedNode!.x ?? 0.5) +
            details.focalPointDelta.dx / (_scale * canvasSize.width);
        _draggedNode!.y = (_draggedNode!.y ?? 0.5) +
            details.focalPointDelta.dy / (_scale * canvasSize.height);
        _draggedNode!.x = _draggedNode!.x!.clamp(0.05, 0.95);
        _draggedNode!.y = _draggedNode!.y!.clamp(0.05, 0.95);
      }
    });
  }

  void _onTapUp(TapUpDetails details, Size canvasSize) {
    final lx = (details.localPosition.dx - _offset.dx) / _scale;
    final ly = (details.localPosition.dy - _offset.dy) / _scale;
    final hitNode = _hitTestLayout(Offset(lx, ly), canvasSize);

    if (hitNode != null) {
      setState(() => _selectedNode = hitNode);
      _showDetailSheet(hitNode);
    } else {
      setState(() => _selectedNode = null);
    }
  }

  /// 在布局坐标系中检测命中了哪个节点
  ///
  /// [layoutPos] 已经是 canvas 像素坐标 `(local - offset) / scale`。
  GraphNode? _hitTestLayout(Offset layoutPos, Size canvasSize) {
    for (final node in _nodes) {
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
