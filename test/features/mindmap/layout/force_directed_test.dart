import 'package:test/test.dart';
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

      final layout = ForceDirectedLayout(nodes: nodes, edges: edges);
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
      final layout = ForceDirectedLayout(nodes: [], edges: []);
      layout.run(); // 不应抛异常
    });

    test('节点半径与 weight 成正比', () {
      final nodes = [
        GraphNode(id: 'big', label: 'Big', type: 'topic', weight: 1.0),
        GraphNode(id: 'small', label: 'Small', type: 'insight', weight: 0.2),
      ];
      final layout = ForceDirectedLayout(nodes: nodes, edges: []);
      layout.run();

      final bigNode = nodes[0];
      final smallNode = nodes[1];
      expect(bigNode.radius!, greaterThan(smallNode.radius!));
    });

    test('连线相连的节点位置更近', () {
      final nodes = [
        GraphNode(id: 'a', label: 'A', type: 'topic', weight: 0.5),
        GraphNode(id: 'b', label: 'B', type: 'insight', weight: 0.5),
        GraphNode(id: 'c', label: 'C', type: 'value', weight: 0.5),
      ];
      // a-b 有连线，c 孤立
      final edges = [
        GraphEdge(source: 'a', target: 'b'),
      ];

      final layout = ForceDirectedLayout(nodes: nodes, edges: edges);
      layout.run(iterations: 100);

      final distAB = _distance(nodes[0], nodes[1]);
      final distAC = _distance(nodes[0], nodes[2]);
      final distBC = _distance(nodes[1], nodes[2]);

      // 有连线的节点距离应该小于平均的孤立节点距离
      final avgIsolated = (distAC + distBC) / 2;
      expect(distAB, lessThan(avgIsolated));
    });

    test('布局可复现（固定种子）', () {
      final nodes1 = [
        GraphNode(id: 'a', label: 'A', type: 'topic', weight: 0.5),
        GraphNode(id: 'b', label: 'B', type: 'insight', weight: 0.5),
      ];
      final edges = [
        GraphEdge(source: 'a', target: 'b'),
      ];

      final layout1 = ForceDirectedLayout(nodes: nodes1, edges: edges);
      layout1.run(iterations: 20);

      // 第二轮独立节点
      final nodes2 = [
        GraphNode(id: 'a', label: 'A', type: 'topic', weight: 0.5),
        GraphNode(id: 'b', label: 'B', type: 'insight', weight: 0.5),
      ];
      final layout2 = ForceDirectedLayout(nodes: nodes2, edges: edges);
      layout2.run(iterations: 20);

      expect(nodes1[0].x, nodes2[0].x);
      expect(nodes1[0].y, nodes2[0].y);
      expect(nodes1[1].x, nodes2[1].x);
      expect(nodes1[1].y, nodes2[1].y);
    });
  });
}

double _distance(GraphNode a, GraphNode b) {
  final dx = a.x! - b.x!;
  final dy = a.y! - b.y!;
  return dx * dx + dy * dy; // 用平方距离比较（避免 sqrt）
}
