import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:open_aot_patch_tools/open_aot_patch_tools.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/artifact_builder/ios_bytecode_builder.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';
import 'package:yaml/yaml.dart';

/// Independently measures the packaged baseline and its compiled scope/policy.
/// This consumes downloaded archive bytes, never the requested registration.
class ReleaseSelectionArchive {
  /// Verifies every device Flutter-assets directory in the release archive.
  static ReleaseSelectionScope verifyPackage(
    File file, {
    required String appId,
    required String version,
    required String platform,
    required String expectedPublicKey,
  }) {
    final archive = ZipDecoder().decodeBytes(file.readAsBytesSync());
    final policies = archive.files
        .where(
          (f) =>
              f.isFile &&
              f.name.endsWith('/flutter_assets/shorebird.yaml') &&
              !f.name.contains('simulator'),
        )
        .toList();
    if (policies.isEmpty) {
      throw const FormatException('Missing compiled release policy');
    }
    ReleaseSelectionScope? result;
    for (final policy in policies) {
      final prefix = p.posix.dirname(policy.name);
      List<int> member(String name) {
        final matches = archive.files
            .where((f) => f.isFile && f.name == '$prefix/$name')
            .toList();
        if (matches.length != 1) {
          throw FormatException('Missing or duplicate packaged $name');
        }
        return matches.single.content as List<int>;
      }

      final yaml =
          loadYaml(utf8.decode(policy.content as List<int>)) as YamlMap;
      final scope = ReleaseSelectionScope.decode(
        utf8.decode(
          member('shorebird_release_scope_${platform}_aarch64.json'),
        ),
      );
      final profile = yaml['aot_patch_full_replacement'] == true
          ? 'interpreter-full'
          : yaml['aot_patch_structural_updates'] == true
          ? 'interpreter-structural'
          : 'interpreter-body';
      final baseline = member(
        profile == 'interpreter-full'
            ? 'shorebird_replacement_base.sbr'
            : 'shorebird_interpreter_base.bytecode',
      );
      if (scope.appId != appId ||
          scope.releaseVersion != version ||
          scope.platform != platform ||
          scope.arch != 'aarch64' ||
          scope.runtimeProfile != profile ||
          sha256.convert(baseline).toString() != scope.baseArtifactHash ||
          yaml['selection_protocol'] != 2 ||
          yaml['app_id'] != appId ||
          yaml['aot_patch_runtime_mode'] != 'dart-bytecode-interpreter' ||
          yaml['aot_patch_base_snapshot_hash'] != scope.baseArtifactHash ||
          (yaml['aot_patch_app_build_id'] != null &&
              yaml['aot_patch_app_build_id'] != version) ||
          yaml['aot_patch_host_abi'] != scope.hostAbiHash ||
          yaml['patch_verification'] != 'strict' ||
          yaml['patch_response_verification'] != 'required' ||
          yaml['patch_public_key'] != expectedPublicKey ||
          yaml['aot_patch_app_build_id'] != scope.releaseVersion ||
          yaml['patch_public_key'] is! String ||
          (yaml['patch_public_key'] as String).isEmpty ||
          yaml['aot_patch_key_hex'] != null ||
          (result != null &&
              jsonEncode(result.toJson()) != jsonEncode(scope.toJson()))) {
        throw const FormatException(
          'Packaged immutable selection binding mismatch',
        );
      }
      if (profile == 'interpreter-full') {
        final wrapper = FullReplacementBundle.decode(baseline);
        if (!wrapper.manifest.isBaseline ||
            wrapper.manifest.hostAbiHex != scope.hostAbiHash) {
          throw const FormatException(
            'Packaged full baseline host ABI mismatch',
          );
        }
      }
      result = scope;
    }
    return result!;
  }

  /// Confirms the separately uploaded original supplement matches the package.
  static Map<String, Object?> verifySupplement(
    File file,
    ReleaseSelectionScope scope,
  ) {
    final archive = ZipDecoder().decodeBytes(file.readAsBytesSync());
    List<int> member(String name) {
      final matches = archive.files
          .where((f) => f.isFile && p.posix.basename(f.name) == name)
          .toList();
      if (matches.length != 1) {
        throw FormatException('Missing or duplicate supplement $name');
      }
      return matches.single.content as List<int>;
    }

    final manifest =
        jsonDecode(utf8.decode(member(IosBytecodeBuilder.manifestFileName)))
            as Map<String, dynamic>;
    if (sha256
                .convert(member(IosBytecodeBuilder.baselineFileName))
                .toString() !=
            scope.baseArtifactHash ||
        manifest['base_snapshot_hash'] != scope.baseArtifactHash ||
        manifest['app_id'] != scope.appId ||
        manifest['app_build_id'] != scope.releaseVersion ||
        manifest['selection_protocol'] != 2 ||
        manifest['host_abi'] != scope.hostAbiHash) {
      throw const FormatException(
        'Original release supplement differs from packaged scope',
      );
    }
    return manifest.cast<String, Object?>();
  }
}
