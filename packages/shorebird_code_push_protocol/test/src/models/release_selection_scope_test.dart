import 'dart:convert';

import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';
import 'package:test/test.dart';

void main() {
  Map<String, dynamic> scope() => {
    'app_id': '11111111-1111-4111-8111-111111111111',
    'release_version': '1.0.0+1',
    'platform': 'ios',
    'arch': 'aarch64',
    'base_artifact_hash': 'aa' * 32,
    'host_abi_hash': null,
    'runtime_profile': 'interpreter-body',
  };

  test('decodes whitespace, null and escaped string content', () {
    final fields = scope()..['release_version'] = '1.0.0+1\\"\n';
    final source = '\n ${const JsonEncoder.withIndent('  ').convert(fields)}\t';
    expect(ReleaseSelectionScope.decode(source).toJson(), fields);
  });

  test('decodes escaped keys and full-profile host ABI', () {
    final fields = scope()
      ..['host_abi_hash'] = 'bb' * 32
      ..['runtime_profile'] = 'interpreter-full';
    final source = jsonEncode(fields).replaceFirst(
      'base_artifact_hash',
      r'base_artifact_\u0068ash',
    );
    expect(ReleaseSelectionScope.decode(source).toJson(), fields);
  });

  for (final key in ['base_artifact_hash', r'base_artifact_\u0068ash']) {
    test('rejects duplicate decoded field $key', () {
      final source =
          '{"$key":"${'ff' * 32}",${jsonEncode(scope()).substring(1)}';
      expect(() => ReleaseSelectionScope.decode(source), throwsFormatException);
    });
  }

  for (final source in [
    '{}',
    '[]',
    '{',
    '{"app_id":',
    '{"app_id":"unterminated',
    r'{"app_id":"unterminated\',
    '{"app_id":42}',
    '{"app_id":{}}',
    '{"app_id":[]}',
    r'{"app_id":"invalid\q"}',
  ]) {
    test('rejects malformed flat JSON $source', () {
      expect(() => ReleaseSelectionScope.decode(source), throwsFormatException);
    });
  }

  test('rejects trailing commas, trailing JSON and unknown fields', () {
    final valid = jsonEncode(scope());
    for (final source in [
      '${valid.substring(0, valid.length - 1)},}',
      '$valid {}',
      jsonEncode({...scope(), 'variant': 'pro'}),
    ]) {
      expect(() => ReleaseSelectionScope.decode(source), throwsFormatException);
    }
  });
}
