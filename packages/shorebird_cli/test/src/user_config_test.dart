import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/user_config.dart';
import 'package:test/test.dart';

void main() {
  group(UserConfig, () {
    late File configFile;
    late UserConfig userConfig;

    setUp(() {
      configFile = File(
        p.join(Directory.systemTemp.createTempSync().path, 'config.json'),
      );
      userConfig = UserConfig(file: configFile);
    });

    test('returns null when config file does not exist', () {
      expect(userConfig.hostedUri, isNull);
    });

    test('persists hostedUri as base_url', () {
      final uri = Uri.parse('https://updates.example.com');

      userConfig.setHostedUri(uri);

      expect(userConfig.hostedUri, equals(uri));
      expect(
        json.decode(configFile.readAsStringSync()),
        equals({'base_url': 'https://updates.example.com'}),
      );
    });

    test('preserves unrelated config values', () {
      configFile
        ..createSync(recursive: true)
        ..writeAsStringSync(json.encode({'existing': true}));

      userConfig.setHostedUri(Uri.parse('https://updates.example.com'));

      expect(
        json.decode(configFile.readAsStringSync()),
        equals({
          'existing': true,
          'base_url': 'https://updates.example.com',
        }),
      );
    });

    test('ignores malformed config files', () {
      configFile
        ..createSync(recursive: true)
        ..writeAsStringSync('{');

      expect(userConfig.hostedUri, isNull);
    });
  });
}
