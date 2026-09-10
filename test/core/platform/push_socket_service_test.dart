import 'package:flutter_test/flutter_test.dart';
import 'package:zhixing_ai/core/platform/push_socket_service.dart';

void main() {
  test('parsePushMessage parses valid push', () {
    final m = parsePushMessage('{"type":"push","title":"t","body":"b"}');
    expect(m, isNotNull);
    expect(m!.title, 't');
    expect(m.body, 'b');
  });

  test('parsePushMessage returns null for non-push type', () {
    expect(parsePushMessage('{"type":"other"}'), isNull);
  });

  test('parsePushMessage returns null for invalid json', () {
    expect(parsePushMessage('not json'), isNull);
  });

  test('buildWsUrl embeds token', () {
    expect(buildWsUrl('abc'), endsWith('/ws?token=abc'));
  });
}
