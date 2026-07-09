import 'dart:math';

import 'package:socratic_ai/core/models/chat_models.dart';

/// 图谱布局算法
///
/// 两步法：
/// 1. 辐射分布：所有节点均匀分布在以 (0.5,0.5) 为圆心的圆上
/// 2. 弱力微调：连线节点互相吸引，所有节点互相轻推 + 中心引力回拉
class ForceDirectedLayout {
  final List<GraphNode> nodes;
  final List<GraphEdge> edges;

  static const double _minRadius = 36.0;
  static const double _maxRadius = 56.0;

  ForceDirectedLayout({
    required this.nodes,
    required this.edges,
  });

  void run({int? iterations}) {
    if (nodes.isEmpty) return;

    // ── 1. 辐射分布 ──
    final count = nodes.length;
    final angleStep = 2 * pi / count;
    for (int i = 0; i < count; i++) {
      final node = nodes[i];
      node.x = 0.5 + 0.3 * cos(angleStep * i);
      node.y = 0.5 + 0.3 * sin(angleStep * i);
      node.vx = 0;
      node.vy = 0;
    }

    // ── 2. 弱力微调 ──
    const maxIter = 100;
    for (int iter = 0; iter < maxIter; iter++) {
      for (final node in nodes) {
        double fx = 0;
        double fy = 0;

        // 微斥力：其他节点轻轻推开
        for (final other in nodes) {
          if (identical(other, node)) continue;
          final dx = node.x! - other.x!;
          final dy = node.y! - other.y!;
          final dist = max(sqrt(dx * dx + dy * dy), 0.05);
          final force = 0.001 / dist;
          fx += (dx / dist) * force;
          fy += (dy / dist) * force;
        }

        // 微引力：连线节点靠近
        for (final edge in edges) {
          GraphNode? target;
          if (edge.source == node.id) {
            target = _findNode(edge.target);
          } else if (edge.target == node.id) {
            target = _findNode(edge.source);
          }
          if (target == null || target.x == null || target.y == null) continue;
          final dx = target.x! - node.x!;
          final dy = target.y! - node.y!;
          final dist = sqrt(dx * dx + dy * dy).clamp(0.05, 5.0);
          final force = dist * 0.01 * edge.strength;
          fx += dx / dist * force;
          fy += dy / dist * force;
        }

        // 中心引力
        fx += (0.5 - node.x!) * 0.01;
        fy += (0.5 - node.y!) * 0.01;

        // 更新速度
        node.vx = (node.vx! + fx.clamp(-0.05, 0.05)) * 0.7;
        node.vy = (node.vy! + fy.clamp(-0.05, 0.05)) * 0.7;
      }

      // 应用速度 + 边界钳制
      for (final node in nodes) {
        node.x = (node.x! + node.vx!).clamp(0.15, 0.85);
        node.y = (node.y! + node.vy!).clamp(0.15, 0.85);
      }
    }

    // ── 3. 计算半径 ──
    for (final node in nodes) {
      node.radius = _minRadius + (_maxRadius - _minRadius) * node.weight;
    }
  }

  GraphNode? _findNode(String id) {
    try {
      return nodes.firstWhere((n) => n.id == id);
    } catch (_) {
      return null;
    }
  }
}
