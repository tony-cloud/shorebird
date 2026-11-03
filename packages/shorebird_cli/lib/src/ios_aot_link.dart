import 'dart:convert';
import 'dart:io';

import 'package:open_aot_patch_tools/open_aot_patch_tools.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:yaml/yaml.dart';

/// Environment variables flutter_tools reads for the `aot-link` profile
/// (flutter_tools `lib/src/shorebird/shorebird_aot_link.dart`).
abstract final class AotLinkEnvironment {
  /// The release sidecar; its presence makes the build a patch build.
  static const base = 'SHOREBIRD_AOT_LINK_BASE';

  /// The release's DD targets, for patches of a DD release.
  static const ddTargets = 'SHOREBIRD_AOT_LINK_DD_TARGETS';

  /// DD threshold of a release; unset means no DD.
  static const ddMaxBytes = 'SHOREBIRD_AOT_LINK_DD_MAX_BYTES';

  /// Comma-separated packages DD targets may come from.
  static const ddPackages = 'SHOREBIRD_AOT_LINK_DD_PACKAGES';

  /// The `ios_linker` tool.
  static const tool = 'SHOREBIRD_IOS_LINKER';
}

/// Whether this project selects the iOS `aot-link` profile.
///
/// The profile is chosen by `aot_patch_runtime_mode: ios-aot-link` in
/// shorebird.yaml, because flutter_tools reads the same file to decide how to
/// compile. `SHOREBIRD_IOS_PATCH_RUNTIME_MODE` may restate it but not
/// contradict it in either direction.
bool iosAotLinkSelected() {
  final yamlMode = shorebirdEnv.getShorebirdYaml()?.aotPatchRuntimeMode;
  final envMode = platform.environment['SHOREBIRD_IOS_PATCH_RUNTIME_MODE']
      ?.trim();
  final yamlSelects = yamlMode == runtimeModeIosAotLink;
  if (envMode != null && envMode.isNotEmpty) {
    if ((envMode == runtimeModeIosAotLink) != yamlSelects) {
      throw const AotLinkConfigurationException(
        'SHOREBIRD_IOS_PATCH_RUNTIME_MODE and aot_patch_runtime_mode in '
        'shorebird.yaml disagree about ios-aot-link. flutter_tools compiles '
        'from shorebird.yaml, so set it there.',
      );
    }
  }
  return yamlSelects;
}

/// A configuration the `aot-link` profile does not allow.
class AotLinkConfigurationException implements Exception {
  /// Creates the exception.
  const AotLinkConfigurationException(this.message);

  /// What to change.
  final String message;

  @override
  String toString() => message;
}

/// The packages DD may select targets from: the app itself and the packages
/// it takes by path (workspace members, monorepo siblings), never the SDK,
/// Flutter or packages from pub.
List<String> appOwnPackages(Directory projectRoot) {
  final names = <String>{};
  final pubspec = File(p.join(projectRoot.path, 'pubspec.yaml'));
  final root = pubspec.existsSync()
      ? loadYaml(pubspec.readAsStringSync())
      : null;
  if (root is YamlMap) {
    if (root['name'] case final String name) names.add(name);
    for (final section in const ['dependencies', 'dev_dependencies']) {
      if (root[section] case final YamlMap dependencies) {
        for (final entry in dependencies.entries) {
          if (entry.value is YamlMap &&
              (entry.value as YamlMap)['path'] != null) {
            names.add(entry.key as String);
          }
        }
      }
    }
  }
  final config = File(
    p.join(projectRoot.path, '.dart_tool', 'package_config.json'),
  );
  if (config.existsSync()) {
    final json = jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
    final base = p.dirname(config.path);
    for (final package
        in (json['packages'] as List).cast<Map<String, dynamic>>()) {
      final uri = Uri.parse(package['rootUri'] as String);
      final resolved = p.normalize(
        uri.isScheme('file')
            ? uri.toFilePath()
            : p.join(base, uri.toFilePath()),
      );
      if (p.isWithin(projectRoot.path, resolved) ||
          p.equals(projectRoot.path, resolved)) {
        names.add(package['name'] as String);
      }
    }
  }
  return names.toList()..sort();
}
