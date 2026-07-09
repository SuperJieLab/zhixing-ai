import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:socratic_ai/core/models/chat_models.dart';
import 'package:socratic_ai/core/theme.dart';

/// 思维图谱 CustomPainter
///
/// 绘制节点（圆形 + 标签 + 分类标签）和连线（直线 + 关系标签）。
/// 节点颜色按 type 分类，线宽按 edge.strength 变化。
/// 支持选中态高亮和缩放适配。
class GraphPainter extends CustomPainter {
  final List<GraphNode> nodes;
  final List<GraphEdge> edges;
  final GraphNode? selectedNode;
  final double scale;
  final Offset offset;

  GraphPainter({
    required this.nodes,
    required this.edges,
    this.selectedNode,
    this.scale = 1.0,
    this.offset = Offset.zero,
  });

  // ================================================================
  // 节点颜色映射
  // ================================================================

  static Color _nodeColor(String type) {
    switch (type) {
      case 'topic':
        return AppTheme.primary;
      case 'insight':
        return const Color(0xFF5B8D8D);
      case 'value':
        return AppTheme.secondary;
      case 'action':
        return AppTheme.accent;
      case 'contradiction':
        return const Color(0xFFD4735B);
      default:
        return AppTheme.primary;
    }
  }

  static Color _nodeFillColor(String type) {
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

  static String _typeLabel(String type) {
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

  // ================================================================
  // 绘制
  // ================================================================

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(scale);
    _drawEdges(canvas, size);
    _drawNodes(canvas, size);
    canvas.restore();
  }

  void _drawEdges(Canvas canvas, Size size) {
    for (final edge in edges) {
      final source = _findNode(edge.source);
      final target = _findNode(edge.target);
      if (source == null || target == null) continue;
      if (source.x == null || source.y == null) continue;
      if (target.x == null || target.y == null) continue;

      final x1 = source.x! * size.width;
      final y1 = source.y! * size.height;
      final x2 = target.x! * size.width;
      final y2 = target.y! * size.height;

      final paint = Paint()
        ..color = const Color(0xFFD0C8C0)
        ..strokeWidth = 1.0 + edge.strength * 2.5
        ..style = PaintingStyle.stroke;

      canvas.drawLine(Offset(x1, y1), Offset(x2, y2), paint);

      // 关系标签（连线中点）
      if (edge.label.isNotEmpty) {
        final midX = (x1 + x2) / 2;
        final midY = (y1 + y2) / 2;
        final tp = TextPainter(
          text: TextSpan(
            text: edge.label,
            style: TextStyle(
              fontSize: 10,
              color: AppTheme.textSecondary,
              background: Paint()..color = AppTheme.background.withValues(alpha: 0.85),
            ),
          ),
          textDirection: ui.TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(midX - tp.width / 2, midY - tp.height / 2));
      }
    }
  }

  void _drawNodes(Canvas canvas, Size size) {
    for (final node in nodes) {
      if (node.x == null || node.y == null) continue;

      final cx = node.x! * size.width;
      final cy = node.y! * size.height;
      final r = node.radius ?? 32;
      final isSelected = node.id == selectedNode?.id;
      final color = _nodeColor(node.type);
      final fillColor = _nodeFillColor(node.type);

      // 选中态光晕
      if (isSelected) {
        final glowPaint = Paint()
          ..color = color.withValues(alpha: 0.15)
          ..style = PaintingStyle.fill
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
        canvas.drawCircle(Offset(cx, cy), r + 6, glowPaint);
      }

      // 填充圆
      final fillPaint = Paint()
        ..color = isSelected ? color : fillColor
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(cx, cy), r, fillPaint);

      // 边框
      final strokePaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = isSelected ? 2.5 : 1.5;
      canvas.drawCircle(Offset(cx, cy), r, strokePaint);

      // 节点标签（限制两行）
      final labelMaxWidth = r * 1.8;
      final tp = TextPainter(
        text: TextSpan(
          text: node.label,
          style: TextStyle(
            fontSize: (isSelected ? 14 : 13),
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
            color: isSelected ? color : AppTheme.textPrimary,
            height: 1.3,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
        maxLines: 2,
        ellipsis: '...',
      )..layout(maxWidth: labelMaxWidth);
      tp.paint(canvas, Offset(cx - tp.width / 2, cy - tp.height / 2));

      // 分类标签（节点下方）
      final tag = _typeLabel(node.type);
      final tagPainter = TextPainter(
        text: TextSpan(
          text: tag,
          style: TextStyle(
            fontSize: 9,
            color: AppTheme.textSecondary,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      tagPainter.paint(
        canvas,
        Offset(cx - tagPainter.width / 2, cy + r + 4),
      );
    }
  }

  // ================================================================
  // 工具
  // ================================================================

  GraphNode? _findNode(String id) {
    try {
      return nodes.firstWhere((n) => n.id == id);
    } catch (_) {
      return null;
    }
  }

  @override
  bool shouldRepaint(covariant GraphPainter oldDelegate) {
    return oldDelegate.scale != scale ||
        oldDelegate.offset != offset ||
        oldDelegate.selectedNode?.id != selectedNode?.id ||
        oldDelegate.nodes != nodes;
  }
}
