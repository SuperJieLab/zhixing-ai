import 'dart:math';

import 'package:socratic_ai/core/models/chat_models.dart';

/// Force-directed 图谱布局算法
///
/// 纯 Dart 实现，不依赖外部库。
/// 接收图结构（节点 + 连线），计算每个节点的 (x, y) 坐标和 radius。
///
/// 算法核心：
/// 1. 每个节点受三种力：节点间斥力 + 连线吸引力 + 中心引力
/// 2. 迭代 N 次，每次计算合力 → 更新位置 + 阻尼衰减
/// 3. 最终坐标系归一化到 [0, 1] 范围内
///
/// 使用方式：
/// ```dart
/// final layout = ForceDirectedLayout(nodes: nodes, edges: edges);
/// layout.run(iterations: 100);
/// ```
class ForceDirectedLayout {
  final List<GraphNode> nodes;
  final List<GraphEdge> edges;

  // 算法参数
  static const double _repulsionStrength = 80.0;
  static const double _attractionStrength = 0.03;
  static const double _damping = 0.88;
  static const double _minVelocity = 0.01;
  static const double _maxForce = 10.0;
  static const int _maxIterations = 150;

  // 节点半径范围
  static const double _minRadius = 36.0;
  static const double _maxRadius = 56.0;

  ForceDirectedLayout({
    required this.nodes,
    required this.edges,
  });

  /// 运行布局算法，计算所有节点的坐标和半径
  void run({int? iterations}) {
    if (nodes.isEmpty) return;

    final maxIter = iterations ?? _maxIterations;
    final rng = Random(42); // 固定种子，保证布局可复现

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
        double fx = 0;
        double fy = 0;

        // 斥力：所有其他节点对本节点的排斥
        for (final other in nodes) {
          if (identical(other, node)) continue;
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
            target = _findNode(edge.target);
          } else if (edge.target == node.id) {
            target = _findNode(edge.source);
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
        fx += (0.5 - node.x!) * 0.03;
        fy += (0.5 - node.y!) * 0.03;

        // 边界约束力
        const margin = 0.15;
        if (node.x! < margin) fx += (margin - node.x!) * 0.8;
        if (node.x! > 1.0 - margin) fx -= (node.x! - (1.0 - margin)) * 0.8;
        if (node.y! < margin) fy += (margin - node.y!) * 0.8;
        if (node.y! > 1.0 - margin) fy -= (node.y! - (1.0 - margin)) * 0.8;

        // 更新速度（含阻尼衰减和力上限）
        fx = fx.clamp(-_maxForce, _maxForce);
        fy = fy.clamp(-_maxForce, _maxForce);
        node.vx = (node.vx! + fx) * _damping;
        node.vy = (node.vy! + fy) * _damping;

        totalEnergy += node.vx!.abs() + node.vy!.abs();
      }

      // 应用速度 + 位置裁剪
      for (final node in nodes) {
        node.x = (node.x! + node.vx!).clamp(0.0, 1.0);
        node.y = (node.y! + node.vy!).clamp(0.0, 1.0);
      }

      // 提前收敛
      if (totalEnergy < _minVelocity * nodes.length) break;
    }

    // 3. 计算半径（与 weight 成正比）
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
