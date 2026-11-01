import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';
import 'package:yaml/yaml.dart';

/// Measures final packaged native AOT libraries.
class NativeSelectionArchive {
  /// Platforms which use the native two-pass selection producer.
  static const platforms = {'android', 'linux', 'windows'};

  /// Reads a package without extracting untrusted archive paths.
  static Archive read(FileSystemEntity package) {
    if (package is File) {
      return ZipDecoder().decodeBytes(package.readAsBytesSync());
    }
    final archive = Archive();
    for (final file
        in (package as Directory).listSync(recursive: true).whereType<File>()) {
      final name = p
          .relative(file.path, from: package.path)
          .split(p.separator)
          .join('/');
      archive.addFile(
        ArchiveFile(name, file.lengthSync(), file.readAsBytesSync()),
      );
    }
    return archive;
  }

  /// Requires exactly one member of the package.
  static List<int> member(Archive archive, String name) {
    final files = archive.files
        .where((f) => f.isFile && f.name == name)
        .toList();
    if (files.length != 1) {
      throw FormatException('Missing or duplicate packaged $name');
    }
    return files.single.content as List<int>;
  }

  /// Exact final runtime library location in each supported package.
  static String libraryPath(String platform, String arch) => switch (platform) {
    'android' =>
      'base/lib/${switch (arch) {
        'arm' => 'armeabi-v7a',
        'aarch64' => 'arm64-v8a',
        'x86_64' => 'x86_64',
        _ => throw const FormatException('Unsupported Android architecture'),
      }}/libapp.so',
    'linux' => 'lib/libapp.so',
    'windows' => 'data/app.so',
    _ => throw const FormatException('Unsupported native selection platform'),
  };

  /// All native application AOT libraries use ELF, including Windows app.so.
  static void validateMachine(List<int> bytes, String arch) {
    final machine = switch (arch) {
      'arm' => 40,
      'aarch64' => 183,
      'x86_64' => 62,
      _ => -1,
    };
    if (bytes.length < 20 ||
        bytes[0] != 0x7f ||
        bytes[1] != 0x45 ||
        bytes[2] != 0x4c ||
        bytes[3] != 0x46 ||
        bytes[4] != (arch == 'arm' ? 1 : 2) ||
        bytes[5] != 1 ||
        ByteData.sublistView(
              Uint8List.fromList(bytes),
            ).getUint16(18, Endian.little) !=
            machine) {
      throw FormatException('Packaged native AOT library is not $arch ELF');
    }
  }

  /// Extracts final baseline bytes for the complete requested set.
  static Map<String, List<int>> baselines(
    FileSystemEntity package,
    String platform,
    Iterable<String> arches,
  ) {
    final archive = read(package);
    final requested = arches.toSet();
    if (requested.isEmpty || (platform != 'android' && requested.length != 1)) {
      throw const FormatException('Invalid native package architecture set');
    }
    final result = <String, List<int>>{};
    for (final arch in requested) {
      final bytes = member(archive, libraryPath(platform, arch));
      validateMachine(bytes, arch);
      result[arch] = bytes;
    }
    if (platform == 'android') {
      final names = archive.files
          .where(
            (f) =>
                f.isFile &&
                RegExp(r'^base/lib/[^/]+/libapp\.so$').hasMatch(f.name),
          )
          .map((f) => f.name)
          .toSet();
      if (names.length != requested.length ||
          !names.containsAll(
            requested.map((arch) => libraryPath(platform, arch)),
          )) {
        throw const FormatException(
          'AAB native architecture set differs from requested set',
        );
      }
    }
    return result;
  }

  /// Verifies compiled trust policy and every exact seven-field public scope.
  /// For a patch, [expectedScopes] remains the original release identity while
  /// its new library is checked for architecture rather than base hash.
  static Map<String, ReleaseSelectionScope> verify(
    FileSystemEntity package, {
    required String appId,
    required String version,
    required String platform,
    required Iterable<String> arches,
    required String expectedPublicKey,
    required int? expectedNativePatchMaxBytes,
    Map<String, ReleaseSelectionScope>? expectedScopes,
  }) {
    final archive = read(package);
    final requested = arches.toSet();
    final libraries = baselines(package, platform, requested);
    final policies = archive.files
        .where(
          (f) => f.isFile && f.name.endsWith('/flutter_assets/shorebird.yaml'),
        )
        .toList();
    if (policies.length != 1) {
      throw const FormatException(
        'Missing or duplicate compiled native policy',
      );
    }
    final policy = policies.single;
    final runtimePolicy = platform == 'android'
        ? 'base/assets/flutter_assets/shorebird.yaml'
        : 'data/flutter_assets/shorebird.yaml';
    if (policy.name != runtimePolicy) {
      throw const FormatException('Compiled policy is outside runtime assets');
    }
    final prefix = p.posix.dirname(policy.name);
    final yaml = loadYaml(utf8.decode(member(archive, policy.name))) as YamlMap;
    if (yaml['app_id'] != appId ||
        yaml['selection_protocol'] != 2 ||
        yaml['patch_verification'] != 'strict' ||
        yaml['patch_response_verification'] != 'required' ||
        yaml['patch_public_key'] != expectedPublicKey ||
        yaml['aot_patch_app_build_id'] != version ||
        yaml['native_patch_max_bytes'] != expectedNativePatchMaxBytes ||
        (yaml['aot_patch_runtime_mode'] != null &&
            yaml['aot_patch_runtime_mode'] != 'native-aot') ||
        yaml['aot_patch_key_hex'] != null ||
        yaml['aot_patch_host_abi'] != null) {
      throw const FormatException(
        'Compiled native signing, version or budget policy mismatch',
      );
    }
    final scopeFiles = archive.files
        .where(
          (f) =>
              f.isFile &&
              f.name.startsWith('$prefix/shorebird_release_scope_') &&
              f.name.endsWith('.json'),
        )
        .toList();
    final names = requested
        .map((arch) => '$prefix/shorebird_release_scope_${platform}_$arch.json')
        .toSet();
    if (scopeFiles.length != names.length ||
        !scopeFiles.map((f) => f.name).toSet().containsAll(names)) {
      throw const FormatException(
        'Compiled native scope architecture set mismatch',
      );
    }
    final scopes = <String, ReleaseSelectionScope>{};
    for (final arch in requested) {
      final scope = ReleaseSelectionScope.decode(
        utf8.decode(
          member(
            archive,
            '$prefix/shorebird_release_scope_${platform}_$arch.json',
          ),
        ),
      );
      if (scope.appId != appId ||
          scope.releaseVersion != version ||
          scope.platform != platform ||
          scope.arch != arch ||
          scope.runtimeProfile != 'native-aot' ||
          scope.hostAbiHash != null ||
          (expectedScopes == null
              ? sha256.convert(libraries[arch]!).toString() !=
                    scope.baseArtifactHash
              : jsonEncode(scope.toJson()) !=
                    jsonEncode(expectedScopes[arch]?.toJson()))) {
        throw const FormatException(
          'Packaged native immutable selection binding mismatch',
        );
      }
      scopes[arch] = scope;
    }
    return scopes;
  }
}

/// Private build input. The directory must live until Flutter completes.
class NativeSelectionManifest {
  /// Stores the manifest and original libraries in private temporary files.
  NativeSelectionManifest({
    required this.appId,
    required this.version,
    required this.platform,
    required this.arches,
  }) : directory = Directory.systemTemp.createTempSync(
         'shorebird-native-selection-',
       );

  /// Installed application UUID.
  final String appId;

  /// Exact native release version.
  final String version;

  /// Updater platform.
  final String platform;

  /// Complete updater wire architecture set.
  final List<String> arches;

  /// Private directory containing build inputs.
  final Directory directory;

  /// Absolute private manifest file supplied to Flutter.
  File get file => File(p.join(directory.path, 'manifest.json'));

  /// Writes measurement input or complete original scopes.
  void write({
    Map<String, ReleaseSelectionScope>? scopes,
    Map<String, List<int>>? baselines,
  }) {
    if (scopes != null &&
        (scopes.length != arches.length ||
            !scopes.keys.toSet().containsAll(arches))) {
      throw const FormatException('Incomplete sealed native architecture set');
    }
    final entries = <Map<String, dynamic>>[];
    if (scopes != null) {
      for (final arch in arches) {
        final baseline = File(p.join(directory.path, '$arch.so'))
          ..writeAsBytesSync(baselines![arch]!);
        if (sha256.convert(baseline.readAsBytesSync()).toString() !=
            scopes[arch]!.baseArtifactHash) {
          throw const FormatException(
            'Private baseline differs from sealed scope',
          );
        }
        entries.add({
          'scope': scopes[arch]!.toJson(),
          'original_baseline_path': baseline.absolute.path,
        });
      }
    }
    file.writeAsStringSync(
      jsonEncode({
        'version': 1,
        'mode': scopes == null ? 'measure' : 'sealed',
        'app_id': appId,
        'release_version': version,
        'platform': platform,
        'arches': arches,
        'entries': entries,
      }),
    );
  }

  /// Deletes all private baseline material after the build.
  void dispose() => directory.deleteSync(recursive: true);
}
