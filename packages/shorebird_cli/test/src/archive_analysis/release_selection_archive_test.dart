import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:shorebird_cli/src/archive_analysis/release_selection_archive.dart';
import 'package:test/test.dart';

import '../helpers.dart';

void main() {
  useTempWorkingDirectory();
  const appId = '11111111-1111-4111-8111-111111111111';
  const assets = 'App.app/Frameworks/App.framework/flutter_assets';
  final baseline = utf8.encode('original release bytecode');
  final hash = sha256.convert(baseline).toString();
  Map<String, dynamic> scope() => {
    'app_id': appId,
    'release_version': '1.0.0+1',
    'platform': 'ios',
    'arch': 'aarch64',
    'base_artifact_hash': hash,
    'host_abi_hash': null,
    'runtime_profile': 'interpreter-body',
  };
  File package({
    Map<String, dynamic>? binding,
    List<int>? bytes,
    String? scopeJson,
  }) {
    final members = <String, List<int>>{
      '$assets/shorebird.yaml': utf8.encode('''
app_id: $appId
selection_protocol: 2
patch_verification: strict
patch_response_verification: required
patch_public_key: pinned-key
aot_patch_runtime_mode: dart-bytecode-interpreter
aot_patch_base_snapshot_hash: $hash
aot_patch_app_build_id: 1.0.0+1
'''),
      '$assets/shorebird_release_scope_ios_aarch64.json': utf8.encode(
        scopeJson ?? jsonEncode(binding ?? scope()),
      ),
      '$assets/shorebird_interpreter_base.bytecode': bytes ?? baseline,
    };
    final archive = Archive();
    for (final entry in members.entries) {
      archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
    }
    return File('release.zip')..writeAsBytesSync(ZipEncoder().encode(archive));
  }

  test('measures original packaged bytecode independently of outer hash', () {
    final result = ReleaseSelectionArchive.verifyPackage(
      package(),
      appId: appId,
      version: '1.0.0+1',
      platform: 'ios',
      expectedPublicKey: 'pinned-key',
    );
    expect(result.baseArtifactHash, hash);
    expect(result.toJson().keys, hasLength(7));
    expect(result.toJson(), containsPair('host_abi_hash', null));
  });
  for (final key in ['base_artifact_hash', r'base_artifact_\u0068ash']) {
    test('rejects duplicate decoded scope key $key before binding checks', () {
      final duplicate =
          '{"$key":"${'ff' * 32}",${jsonEncode(scope()).substring(1)}';
      expect(
        () => ReleaseSelectionArchive.verifyPackage(
          package(scopeJson: duplicate),
          appId: appId,
          version: '1.0.0+1',
          platform: 'ios',
          expectedPublicKey: 'pinned-key',
        ),
        throwsFormatException,
      );
    });
  }
  test('rejects a compiled key different from the managed release key', () {
    expect(
      () => ReleaseSelectionArchive.verifyPackage(
        package(),
        appId: appId,
        version: '1.0.0+1',
        platform: 'ios',
        expectedPublicKey: 'other-managed-key',
      ),
      throwsFormatException,
    );
  });
  test('rejects changed bytecode with unchanged compiled scope', () {
    expect(
      () => ReleaseSelectionArchive.verifyPackage(
        package(bytes: utf8.encode('new variant bytecode')),
        appId: appId,
        version: '1.0.0+1',
        platform: 'ios',
        expectedPublicKey: 'pinned-key',
      ),
      throwsFormatException,
    );
  });
  test('rejects release-version mismatch and extra scope fields', () {
    expect(
      () => ReleaseSelectionArchive.verifyPackage(
        package(),
        appId: appId,
        version: '2.0.0+2',
        platform: 'ios',
        expectedPublicKey: 'pinned-key',
      ),
      throwsFormatException,
    );
    expect(
      () => ReleaseSelectionArchive.verifyPackage(
        package(binding: {...scope(), 'variant': 'pro'}),
        appId: appId,
        version: '1.0.0+1',
        platform: 'ios',
        expectedPublicKey: 'pinned-key',
      ),
      throwsFormatException,
    );
  });
  test('requires original supplement bytes and exact installed identity', () {
    final parsed = ReleaseSelectionArchive.verifyPackage(
      package(),
      appId: appId,
      version: '1.0.0+1',
      platform: 'ios',
      expectedPublicKey: 'pinned-key',
    );
    final manifest = {
      'selection_protocol': 2,
      'app_id': appId,
      'app_build_id': '1.0.0+1',
      'base_snapshot_hash': hash,
    };
    File supplement(List<int> bytes) {
      final archive = Archive()
        ..addFile(ArchiveFile('baseline.bytecode', bytes.length, bytes))
        ..addFile(ArchiveFile.string('baseline.json', jsonEncode(manifest)));
      return File('supplement.zip')
        ..writeAsBytesSync(ZipEncoder().encode(archive));
    }

    ReleaseSelectionArchive.verifySupplement(supplement(baseline), parsed);
    expect(
      () => ReleaseSelectionArchive.verifySupplement(
        supplement(utf8.encode('changed')),
        parsed,
      ),
      throwsFormatException,
    );
  });
}
