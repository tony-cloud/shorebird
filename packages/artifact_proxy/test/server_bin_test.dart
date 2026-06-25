import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('health-check exits successfully without binding a server', () async {
    final workingDirectory = _shorebirdRoot();
    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'packages/artifact_proxy/bin/server.dart',
        '--health-check',
      ],
      workingDirectory: workingDirectory.path,
      environment: {
        'SHOREBIRD_ARTIFACT_BASE_URL': 'https://artifacts.example.com/open',
        'ARTIFACT_PROXY_FLUTTER_BASE_URL': 'https://flutter.example.com',
        'PORT': '18080',
      },
    );

    expect(result.exitCode, 0, reason: result.stderr as String?);
    expect(
      result.stdout,
      contains(
        'artifact_proxy ok '
        'shorebird_artifacts=https://artifacts.example.com/open '
        'flutter_artifacts=https://flutter.example.com '
        'port=18080',
      ),
    );
  });
}

Directory _shorebirdRoot() {
  var directory = Directory.current;
  while (true) {
    if (File('${directory.path}/pubspec.yaml').existsSync() &&
        Directory('${directory.path}/packages/artifact_proxy').existsSync()) {
      return directory;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('Could not find Shorebird package root.');
    }
    directory = parent;
  }
}
