import 'package:test/test.dart';
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
          {
            'source': 'n1',
            'target': 'n2',
            'label': '核心矛盾',
            'strength': 0.9,
          },
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
      expect(graph.isEmpty, isTrue);
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
      expect(graph.nodes[0].weight, 0.5); // 默认值
    });

    test('isNotEmpty 在有节点时返回 true', () {
      final json = {
        'nodes': [
          {'id': 'n1', 'label': '测试', 'type': 'topic'},
        ],
      };
      final graph = ConversationGraph.fromJson(json);
      expect(graph.isNotEmpty, isTrue);
    });

    test('nodeCount 和 edgeCount 正确', () {
      final json = {
        'nodes': [
          {'id': 'a', 'label': 'A', 'type': 'topic'},
          {'id': 'b', 'label': 'B', 'type': 'insight'},
          {'id': 'c', 'label': 'C', 'type': 'value'},
        ],
        'edges': [
          {'source': 'a', 'target': 'b'},
          {'source': 'b', 'target': 'c'},
        ],
      };
      final graph = ConversationGraph.fromJson(json);
      expect(graph.nodeCount, 3);
      expect(graph.edgeCount, 2);
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

    test('坐标字段不会序列化（布局运行时数据）', () {
      final node = GraphNode(
        id: 'n1',
        label: 'A',
        type: 'topic',
      );
      node.x = 0.5;
      node.y = 0.3;

      final json = node.toJson();
      expect(json.containsKey('x'), isFalse);
      expect(json.containsKey('y'), isFalse);
    });
  });

  group('GraphEdge JSON 序列化', () {
    test('toJson/fromJson 往返', () {
      final edge = GraphEdge(
        source: 'n1',
        target: 'n2',
        label: '推导出',
        strength: 0.8,
      );

      final restored = GraphEdge.fromJson(edge.toJson());
      expect(restored.source, 'n1');
      expect(restored.target, 'n2');
      expect(restored.label, '推导出');
      expect(restored.strength, 0.8);
    });

    test('默认值', () {
      final edge = GraphEdge(source: 'a', target: 'b');
      expect(edge.label, '');
      expect(edge.strength, 0.5);
    });
  });
}
