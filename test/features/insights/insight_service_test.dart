import 'package:test/test.dart';
import 'package:socratic_ai/core/models/chat_models.dart';

void main() {
  group('ConversationGraph', () {
    test('序列化回合', () {
      final graph = ConversationGraph(
        nodes: [
          GraphNode(id: 'n1', label: '职业转型', type: 'topic', weight: 1.0),
          GraphNode(id: 'n2', label: '能力与运气', type: 'insight', weight: 0.8),
        ],
        edges: [
          GraphEdge(source: 'n1', target: 'n2', label: '核心议题', strength: 0.9),
        ],
      );

      final json = graph.toJson();

      expect(json['nodes'], isA<List>());
      expect((json['nodes'] as List).length, 2);
      expect(json['edges'], isA<List>());
      expect((json['edges'] as List).length, 1);

      final restored = ConversationGraph.fromJson(json);
      expect(restored.nodeCount, 2);
      expect(restored.edgeCount, 1);
      expect(restored.nodes[0].label, '职业转型');
      expect(restored.edges[0].label, '核心议题');
    });

    test('空图谱序列化', () {
      final graph = const ConversationGraph();
      final json = graph.toJson();

      expect(json['nodes'], isEmpty);
      expect(json['edges'], isEmpty);
      expect(graph.isEmpty, isTrue);

      final restored = ConversationGraph.fromJson(json);
      expect(restored.isEmpty, isTrue);
    });
  });
}
