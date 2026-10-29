import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_builder/ios_bytecode_builder.dart';
import 'package:shorebird_cli/src/config/shorebird_yaml.dart';
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
  test('older manifests retain body-only capabilities', () {
    expect(IosBytecodeBuilder.structuralUpdatesForManifest(manifest), isFalse);
    expect(
      IosBytecodeBuilder.validateStructuralProfile(
        const ShorebirdYaml(appId: 'app'),
        manifest,
      ),
      isFalse,
    );
  });
  test('structural manifests require a compiled release profile', () {
    expect(
      () => IosBytecodeBuilder.validateCompiledPolicy(
        File('missing-release.zip'),
        {...manifest, 'structural_updates': true},
      ),
      throwsA(isA<ArtifactBuildException>()),
    );
  });
  for (final enabled in [false, true]) {
    test('validates the compiled structural profile $enabled', () {
      final baseline = {...manifest, 'structural_updates': enabled};
      IosBytecodeBuilder.validateCompiledPolicy(
        releaseWith('$policy\naot_patch_structural_updates: $enabled\n'),
        baseline,
      );
      expect(
        () => IosBytecodeBuilder.validateCompiledPolicy(
          releaseWith('$policy\naot_patch_structural_updates: ${!enabled}\n'),
          baseline,
        ),
        throwsA(isA<ArtifactBuildException>()),
      );
      expect(
        () => IosBytecodeBuilder.validateStructuralProfile(
          ShorebirdYaml(appId: 'app', aotPatchStructuralUpdates: !enabled),
          baseline,
        ),
        throwsA(isA<ArtifactBuildException>()),
      );
    });
  }
  test(
    'refuses malformed structural profile in manifest and bundled policy',
    () {
      for (final invalid in <Object?>['true', 1, null]) {
        expect(
          () => IosBytecodeBuilder.structuralUpdatesForManifest({
            ...manifest,
            'structural_updates': invalid,
          }),
          throwsA(isA<ArtifactBuildException>()),
        );
      }
      expect(
        () => IosBytecodeBuilder.validateCompiledPolicy(
          releaseWith('$policy\naot_patch_structural_updates: "false"\n'),
          manifest,
        ),
        throwsA(isA<ArtifactBuildException>()),
      );
    },
  );
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
