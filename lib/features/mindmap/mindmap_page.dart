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
  double _scale = 1.0;
  Offset _offset = Offset.zero;
  GraphNode? _selectedNode;
  GraphNode? _draggedNode;
  double _baseScale = 1.0;
  Offset _baseOffset = Offset.zero;

  // 布局结果（深拷贝避免影响原始数据）
  late final List<GraphNode> _nodes;
  late final List<GraphEdge> _edges;
  bool _layoutDone = false;

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
    final layout = ForceDirectedLayout(nodes: _nodes, edges: _edges);
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
      body: isEmpty
          ? _buildEmptyState()
          : LayoutBuilder(
              builder: (context, constraints) {
                // 拿到实际尺寸后运行布局
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
  // 图谱交互
  // ================================================================

  Widget _buildGraph() {
    return GestureDetector(
      onScaleStart: _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      onTapUp: _onTapUp,
      child: ClipRect(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final canvasSize = Size(
              constraints.maxWidth,
              constraints.maxHeight,
            );
            return CustomPaint(
              painter: GraphPainter(
                nodes: _nodes,
                edges: _edges,
                selectedNode: _selectedNode,
                scale: _scale,
              ),
              size: canvasSize,
            );
          },
        ),
      ),
    );
  }

  void _onScaleStart(ScaleStartDetails details) {
    _baseScale = _scale;
    _baseOffset = _offset;

    // 检测是否拖拽节点
    final size = MediaQuery.of(context).size;
    final graphPainter = GraphPainter(
      nodes: _nodes,
      edges: _edges,
      scale: _scale,
    );
    final transformedPos = Offset(
      (details.localFocalPoint.dx - _offset.dx) / _scale,
      (details.localFocalPoint.dy - _offset.dy) / _scale,
    );
    _draggedNode = graphPainter.hitTestNode(transformedPos, size);
    if (_draggedNode != null) {
      _selectedNode = _draggedNode;
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    setState(() {
      if (details.pointerCount >= 2 || _draggedNode == null) {
        // 双指缩放 + 平移画布
        _scale = (_baseScale * details.scale).clamp(0.3, 2.5);
        _offset = _baseOffset + details.focalPoint - details.localFocalPoint;
      } else {
        // 单指拖拽节点
        final size = MediaQuery.of(context).size;
        _draggedNode!.x = (_draggedNode!.x ?? 0) +
            details.focalPointDelta.dx / (_scale * size.width);
        _draggedNode!.y = (_draggedNode!.y ?? 0) +
            details.focalPointDelta.dy / (_scale * size.height);
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
    final transformedPos = Offset(
      (details.localPosition.dx - _offset.dx) / _scale,
      (details.localPosition.dy - _offset.dy) / _scale,
    );
    final hitNode = graphPainter.hitTestNode(transformedPos, size);

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
