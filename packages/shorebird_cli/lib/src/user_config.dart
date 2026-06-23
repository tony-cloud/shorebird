import 'dart:convert';
import 'dart:io';

import 'package:cli_util/cli_util.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/shorebird_cli_command_runner.dart';

/// A reference to a [UserConfig] instance.
final userConfigRef = create(UserConfig.new);

/// The [UserConfig] instance available in the current zone.
UserConfig get userConfig => read(userConfigRef);

/// CLI-wide user configuration stored under the Shorebird config directory.
class UserConfig {
  /// Creates a [UserConfig].
  UserConfig({File? file})
    : _file =
          file ??
          File(
            p.join(
              BaseDirectories(executableName).configHome,
              'config.json',
            ),
          );

  final File _file;

  /// The persisted code push API base URL, if any.
  Uri? get hostedUri {
    final value = _read()['base_url'];
    if (value is! String || value.trim().isEmpty) return null;
    return Uri.tryParse(value.trim());
  }

  /// Persists the code push API base URL.
  void setHostedUri(Uri uri) {
    final config = _read();
    config['base_url'] = uri.toString();
    _file
      ..createSync(recursive: true)
      ..writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(config),
        flush: true,
      );
  }

  Map<String, Object?> _read() {
    if (!_file.existsSync()) return <String, Object?>{};
    try {
      final decoded = json.decode(_file.readAsStringSync());
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry('$key', value));
      }
    } on Exception {
      return <String, Object?>{};
    }
    return <String, Object?>{};
  }
}
