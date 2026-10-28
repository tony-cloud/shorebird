import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_builder/ios_bytecode_builder.dart';
import 'package:test/test.dart';

import '../helpers.dart';

void main() {
  useTempWorkingDirectory();
  const manifest = <String, Object?>{
    'app_id': 'app',
    'app_build_id': '1.0.0+1',
    'sdk_hash': 'sdk',
    'base_snapshot_hash': 'measured-bytecode-hash',
    'key_id': 'app-key',
    'base_flavor_id': 'free',
    'base_license_type': 'free',
  };
  const policy = '''
app_id: app
aot_patch_runtime_mode: dart-bytecode-interpreter
aot_patch_sdk_hash: sdk
aot_patch_base_snapshot_hash: measured-bytecode-hash
aot_patch_key_id: app-key
aot_patch_base_flavor_id: free
aot_patch_base_license_type: free
patch_verification: strict
patch_response_verification: required
patch_public_key: pinned-public-key
''';
  File releaseWith(String yaml) {
    final content = utf8.encode(yaml);
    final archive = Archive()
      ..addFile(
        ArchiveFile(
          'Products/Applications/App.app/Frameworks/App.framework/flutter_assets/shorebird.yaml',
          content.length,
          content,
        ),
      );
    return File('release.zip')..writeAsBytesSync(ZipEncoder().encode(archive));
  }

  test('accepts compiled policy matching the private baseline manifest', () {
    IosBytecodeBuilder.validateCompiledPolicy(releaseWith(policy), manifest);
  });
  test('refuses a supplement from a different compiled baseline', () {
    expect(
      () => IosBytecodeBuilder.validateCompiledPolicy(
        releaseWith(policy),
        {...manifest, 'base_snapshot_hash': 'other-hash'},
      ),
      throwsA(isA<ArtifactBuildException>()),
    );
  });
  test('refuses compiled install_only or embedded AES secrets', () {
    for (final yaml in [
      policy.replaceFirst(
        'patch_verification: strict',
        'patch_verification: install_only',
      ),
      '$policy\naot_patch_key_hex: should-never-be-bundled\n',
    ]) {
      expect(
        () => IosBytecodeBuilder.validateCompiledPolicy(
          releaseWith(yaml),
          manifest,
        ),
        throwsA(isA<ArtifactBuildException>()),
      );
    }
  });
}
