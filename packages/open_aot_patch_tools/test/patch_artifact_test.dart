import 'dart:convert';
import 'dart:io';

import 'package:open_aot_patch_tools/open_aot_patch_tools.dart';
import 'package:test/test.dart';

void main() {
  const key = [
    0,
    1,
    2,
    3,
    4,
    5,
    6,
    7,
    8,
    9,
    10,
    11,
    12,
    13,
    14,
    15,
    16,
    17,
    18,
    19,
    20,
    21,
    22,
    23,
    24,
    25,
    26,
    27,
    28,
    29,
    30,
    31,
  ];
  const wrongKey = [
    31,
    30,
    29,
    28,
    27,
    26,
    25,
    24,
    23,
    22,
    21,
    20,
    19,
    18,
    17,
    16,
    15,
    14,
    13,
    12,
    11,
    10,
    9,
    8,
    7,
    6,
    5,
    4,
    3,
    2,
    1,
    0,
  ];
  const nonce = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];

  PatchMetadata metadata({
    String? offlineExpiresAt,
    String targetOs = 'windows',
    String runtimeMode = runtimeModeNativeAot,
  }) => PatchMetadata(
    appId: 'app.test',
    appBuildId: '1.0.0+1',
    baseFlavorId: 'free',
    baseLicenseType: 'free',
    flavorId: 'pro',
    licenseType: 'pro',
    sdkHash: 'sdk',
    baseSnapshotHash: 'base',
    patchSnapshotHash: 'patch',
    targetOs: targetOs,
    targetArch: 'x64',
    runtimeMode: runtimeMode,
    obfuscationMapHash: 'obfuscated',
    offlineExpiresAt: offlineExpiresAt,
  );

  test('encrypts and decrypts flavor-aware patch payloads', () {
    final base = utf8.encode('free');
    final patch = utf8.encode('pro');
    final artifact = linkArtifacts(
      baseSnapshot: base,
      patchSnapshot: patch,
      metadata: metadata(),
    );
    final encrypted = encryptArtifact(
      artifact: artifact,
      keyId: 'test-key',
      key: key,
      nonce: nonce,
    );

    verifyMetadata(encrypted.metadata, flavorId: 'pro', licenseType: 'pro');
    verifyMetadata(
      encrypted.metadata,
      baseFlavorId: 'free',
      baseLicenseType: 'free',
      flavorId: 'pro',
      licenseType: 'pro',
    );
    expect(encrypted.decrypt(key).reconstruct(base), patch);
  });

  test('wrong AES key fails before payload is accepted', () {
    final artifact = linkArtifacts(
      baseSnapshot: utf8.encode('free'),
      patchSnapshot: utf8.encode('pro'),
      metadata: metadata(),
    );
    final encrypted = encryptArtifact(
      artifact: artifact,
      keyId: 'test-key',
      key: key,
      nonce: nonce,
    );

    expect(() => encrypted.decrypt(wrongKey), throwsFormatException);
  });

  test('wrong flavor metadata is rejected', () {
    final artifact = linkArtifacts(
      baseSnapshot: utf8.encode('free'),
      patchSnapshot: utf8.encode('pro'),
      metadata: metadata(),
    );
    final encrypted = encryptArtifact(
      artifact: artifact,
      keyId: 'test-key',
      key: key,
      nonce: nonce,
    );

    expect(
      () => verifyMetadata(
        encrypted.metadata,
        flavorId: 'free',
        licenseType: 'pro',
      ),
      throwsStateError,
    );
  });

  test('wrong base flavor metadata is rejected', () {
    final artifact = linkArtifacts(
      baseSnapshot: utf8.encode('free'),
      patchSnapshot: utf8.encode('pro'),
      metadata: metadata(),
    );
    final encrypted = encryptArtifact(
      artifact: artifact,
      keyId: 'test-key',
      key: key,
      nonce: nonce,
    );

    expect(
      () => verifyMetadata(
        encrypted.metadata,
        baseFlavorId: 'enterprise',
        baseLicenseType: 'free',
        flavorId: 'pro',
        licenseType: 'pro',
      ),
      throwsStateError,
    );
  });

  test('offline expiry is authenticated metadata and enforced', () {
    final expiresAt = DateTime.utc(2030).toIso8601String();
    final expiredAt = DateTime.utc(2031);
    final artifact = linkArtifacts(
      baseSnapshot: utf8.encode('free'),
      patchSnapshot: utf8.encode('pro'),
      metadata: metadata(offlineExpiresAt: expiresAt),
    );
    final encrypted = encryptArtifact(
      artifact: artifact,
      keyId: 'test-key',
      key: key,
      nonce: nonce,
    );

    expect(encrypted.metadata.toJson()['offline_expires_at'], expiresAt);
    expect(
      shouldRemoveInstalledPatchOffline(
        encrypted.metadata,
        now: DateTime.utc(2029),
      ),
      isFalse,
    );
    expect(
      shouldRemoveInstalledPatchOffline(encrypted.metadata, now: expiredAt),
      isTrue,
    );
    expect(
      () => verifyMetadata(
        encrypted.metadata,
        flavorId: 'pro',
        licenseType: 'pro',
        now: expiredAt,
      ),
      throwsStateError,
    );
    verifyMetadata(
      encrypted.metadata,
      flavorId: 'pro',
      licenseType: 'pro',
      now: expiredAt,
      allowExpired: true,
    );
  });

  test('artifact json round trips', () {
    final base = utf8.encode('free');
    final patch = utf8.encode('pro');
    final artifact = linkArtifacts(
      baseSnapshot: base,
      patchSnapshot: patch,
      metadata: metadata(),
    );
    final decoded = PatchArtifact.fromJson(
      (jsonDecode(jsonEncode(artifact.toJson())) as Map).cast(),
    );

    expect(decoded.metadata.flavorId, 'pro');
    expect(decoded.reconstruct(base), patch);
  });

  test('artifact json rejects payload hash mismatch', () {
    final artifact = linkArtifacts(
      baseSnapshot: utf8.encode('free'),
      patchSnapshot: utf8.encode('pro'),
      metadata: metadata(),
    ).toJson()..['payload_sha256'] = 'not-the-real-hash';

    expect(() => PatchArtifact.fromJson(artifact), throwsFormatException);
  });

  test('binary diff payload reconstructs patch snapshot', () {
    final base = List<int>.filled(1024, 7);
    final patch = List<int>.of(base)
      ..[512] = 9
      ..[513] = 10;
    final artifact = linkArtifacts(
      baseSnapshot: base,
      patchSnapshot: patch,
      metadata: metadata(),
    );

    expect(artifact.payloadKind, payloadKindBinaryDiff);
    expect(artifact.payload.length, lessThan(patch.length));
    expect(artifact.reconstruct(base), patch);
  });

  test('full snapshot mode keeps payload directly loadable', () {
    final base = List<int>.filled(1024, 7);
    final patch = List<int>.of(base)..[512] = 9;
    final artifact = linkArtifacts(
      baseSnapshot: base,
      patchSnapshot: patch,
      metadata: metadata(),
      forceFullSnapshot: true,
    );

    expect(artifact.payloadKind, payloadKindFullSnapshot);
    expect(artifact.payload, patch);
    expect(artifact.reconstruct(base), patch);
  });

  test('interpreter runtime keeps payload directly loadable', () {
    final base = List<int>.filled(1024, 7);
    final patch = List<int>.of(base)..[512] = 9;
    final artifact = linkArtifacts(
      baseSnapshot: base,
      patchSnapshot: patch,
      metadata: metadata(
        targetOs: 'ios',
        runtimeMode: runtimeModeDartBytecodeInterpreter,
      ),
    );

    expect(artifact.payloadKind, payloadKindFullSnapshot);
    expect(artifact.payload, patch);
    expect(artifact.reconstruct(base), patch);
  });

  test('iOS native AOT metadata is not App Store-safe', () {
    final iosNative = metadata(targetOs: 'ios');

    expect(iosNative.runtimeMode, runtimeModeNativeAot);
    expect(iosNative.requiresRuntimeExecutableMapping, isTrue);
    expect(iosNative.isIosAppStoreSafe, isFalse);
    expect(
      () => verifyMetadata(
        iosNative,
        flavorId: 'pro',
        licenseType: 'pro',
        requireIosAppStoreSafe: true,
      ),
      throwsStateError,
    );
  });

  test('iOS interpreter metadata satisfies the App Store safety gate', () {
    final iosInterpreter = metadata(
      targetOs: 'ios',
      runtimeMode: runtimeModeDartBytecodeInterpreter,
    );

    expect(iosInterpreter.requiresRuntimeExecutableMapping, isFalse);
    expect(iosInterpreter.isIosAppStoreSafe, isTrue);
    verifyMetadata(
      iosInterpreter,
      flavorId: 'pro',
      licenseType: 'pro',
      requireIosAppStoreSafe: true,
    );
  });

  test('dynamic modules runtime metadata is rejected', () {
    final dynamicModules = metadata(runtimeMode: 'dart-dynamic-modules');

    expect(
      () => verifyMetadata(
        dynamicModules,
        flavorId: 'pro',
        licenseType: 'pro',
      ),
      throwsStateError,
    );
    expect(
      () => dynamicModules.requiresRuntimeExecutableMapping,
      throwsStateError,
    );
  });

  test('cli links encrypts verifies and dumps compact patch', () async {
    final tempDir = Directory.systemTemp.createTempSync(
      'open_aot_patch_tools.',
    );
    try {
      final baseFile = File('${tempDir.path}/base.vmcode')
        ..writeAsBytesSync(List<int>.filled(1024, 7));
      final patchBytes = List<int>.filled(1024, 7)..[512] = 9;
      final patchFile = File('${tempDir.path}/patch.vmcode')
        ..writeAsBytesSync(patchBytes);
      final artifactFile = File('${tempDir.path}/patch.json');
      final encryptedFile = File('${tempDir.path}/patch.enc.json');
      final reconstructedFile = File('${tempDir.path}/reconstructed.vmcode');
      const keyHex =
          '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      const nonceHex = '000102030405060708090a0b';

      await _runTool([
        'link',
        '--base=${baseFile.path}',
        '--patch=${patchFile.path}',
        '--output=${artifactFile.path}',
        '--app-id=app.test',
        '--app-build-id=1.0.0+1',
        '--base-flavor-id=free',
        '--base-license-type=free',
        '--flavor-id=pro',
        '--license-type=pro',
        '--sdk-hash=sdk',
        '--target-os=windows',
        '--target-arch=x64',
      ]);
      final artifactJson = readJsonFile(artifactFile);
      expect(artifactJson['payload_kind'], payloadKindBinaryDiff);

      await _runTool([
        'link',
        '--base=${baseFile.path}',
        '--patch=${patchFile.path}',
        '--output=${artifactFile.path}',
        '--app-id=app.test',
        '--app-build-id=1.0.0+1',
        '--base-flavor-id=free',
        '--base-license-type=free',
        '--flavor-id=pro',
        '--license-type=pro',
        '--sdk-hash=sdk',
        '--target-os=windows',
        '--target-arch=x64',
        '--full-snapshot=true',
        '--offline-expires-at=2030-01-01T00:00:00Z',
      ]);
      final fullArtifactJson = readJsonFile(artifactFile);
      expect(fullArtifactJson['payload_kind'], payloadKindFullSnapshot);
      expect(
        (fullArtifactJson['metadata']! as Map)['offline_expires_at'],
        '2030-01-01T00:00:00.000Z',
      );

      await _runTool([
        'encrypt',
        '--input=${artifactFile.path}',
        '--output=${encryptedFile.path}',
        '--key-id=test-key',
        '--key-hex=$keyHex',
        '--nonce-hex=$nonceHex',
      ]);

      await _runTool([
        'verify',
        '--input=${encryptedFile.path}',
        '--key-hex=$keyHex',
        '--artifact-sha256=${sha256Hex(encryptedFile.readAsBytesSync())}',
        '--base-flavor-id=free',
        '--base-license-type=free',
        '--flavor-id=pro',
        '--license-type=pro',
        '--base=${baseFile.path}',
        '--now=2029-01-01T00:00:00Z',
      ]);

      await _runToolExpectFailure([
        'verify',
        '--input=${encryptedFile.path}',
        '--key-hex=$keyHex',
        '--base-flavor-id=free',
        '--base-license-type=free',
        '--flavor-id=pro',
        '--license-type=pro',
        '--base=${baseFile.path}',
        '--now=2031-01-01T00:00:00Z',
      ]);

      await _runToolExpectFailure([
        'verify',
        '--input=${encryptedFile.path}',
        '--key-hex=$keyHex',
        '--artifact-sha256=bad',
        '--base-flavor-id=free',
        '--base-license-type=free',
        '--flavor-id=pro',
        '--license-type=pro',
        '--base=${baseFile.path}',
      ]);

      await _runTool([
        'link',
        '--base=${baseFile.path}',
        '--patch=${patchFile.path}',
        '--output=${artifactFile.path}',
        '--app-id=app.test',
        '--app-build-id=1.0.0+1',
        '--base-flavor-id=free',
        '--base-license-type=free',
        '--flavor-id=pro',
        '--license-type=pro',
        '--sdk-hash=sdk',
        '--target-os=ios',
        '--target-arch=arm64',
        '--runtime-mode=$runtimeModeNativeAot',
        '--full-snapshot=true',
      ]);
      await _runTool([
        'encrypt',
        '--input=${artifactFile.path}',
        '--output=${encryptedFile.path}',
        '--key-id=test-key',
        '--key-hex=$keyHex',
        '--nonce-hex=$nonceHex',
      ]);
      await _runToolExpectFailure([
        'verify',
        '--input=${encryptedFile.path}',
        '--key-hex=$keyHex',
        '--base-flavor-id=free',
        '--base-license-type=free',
        '--flavor-id=pro',
        '--license-type=pro',
        '--base=${baseFile.path}',
        '--require-ios-app-store-safe=true',
      ]);

      await _runToolExpectFailure([
        'link',
        '--base=${baseFile.path}',
        '--patch=${patchFile.path}',
        '--output=${artifactFile.path}',
        '--app-id=app.test',
        '--app-build-id=1.0.0+1',
        '--base-flavor-id=free',
        '--base-license-type=free',
        '--flavor-id=pro',
        '--license-type=pro',
        '--sdk-hash=sdk',
        '--target-os=ios',
        '--target-arch=arm64',
        '--runtime-mode=dart-dynamic-modules',
        '--full-snapshot=true',
      ]);

      await _runTool([
        'link',
        '--base=${baseFile.path}',
        '--patch=${patchFile.path}',
        '--output=${artifactFile.path}',
        '--app-id=app.test',
        '--app-build-id=1.0.0+1',
        '--base-flavor-id=free',
        '--base-license-type=free',
        '--flavor-id=pro',
        '--license-type=pro',
        '--sdk-hash=sdk',
        '--target-os=ios',
        '--target-arch=arm64',
        '--runtime-mode=$runtimeModeDartBytecodeInterpreter',
      ]);
      final interpreterArtifactJson = readJsonFile(artifactFile);
      expect(interpreterArtifactJson['payload_kind'], payloadKindFullSnapshot);
      await _runTool([
        'encrypt',
        '--input=${artifactFile.path}',
        '--output=${encryptedFile.path}',
        '--key-id=test-key',
        '--key-hex=$keyHex',
        '--nonce-hex=$nonceHex',
      ]);
      await _runTool([
        'verify',
        '--input=${encryptedFile.path}',
        '--key-hex=$keyHex',
        '--base-flavor-id=free',
        '--base-license-type=free',
        '--flavor-id=pro',
        '--license-type=pro',
        '--base=${baseFile.path}',
        '--require-ios-app-store-safe=true',
      ]);

      await _runTool([
        'link',
        '--base=${baseFile.path}',
        '--patch=${patchFile.path}',
        '--output=${artifactFile.path}',
        '--app-id=app.test',
        '--app-build-id=1.0.0+1',
        '--base-flavor-id=free',
        '--base-license-type=free',
        '--flavor-id=pro',
        '--license-type=pro',
        '--sdk-hash=sdk',
        '--target-os=windows',
        '--target-arch=x64',
        '--full-snapshot=true',
        '--offline-expires-at=2030-01-01T00:00:00Z',
      ]);
      await _runTool([
        'encrypt',
        '--input=${artifactFile.path}',
        '--output=${encryptedFile.path}',
        '--key-id=test-key',
        '--key-hex=$keyHex',
        '--nonce-hex=$nonceHex',
      ]);

      final dump = await _runTool([
        'dump-blobs',
        '--input=${encryptedFile.path}',
        '--key-hex=$keyHex',
        '--base=${baseFile.path}',
        '--output=${reconstructedFile.path}',
        '--now=2029-01-01T00:00:00Z',
      ]);
      final dumpJson = (jsonDecode(dump.stdout as String) as Map)
          .cast<String, Object?>();
      expect(
        dumpJson['artifact_sha256'],
        sha256Hex(encryptedFile.readAsBytesSync()),
      );
      expect(dumpJson['reconstructed_patch_sha256'], sha256Hex(patchBytes));
      expect(reconstructedFile.readAsBytesSync(), patchBytes);

      await _runToolExpectFailure([
        'dump-blobs',
        '--input=${encryptedFile.path}',
        '--key-hex=$keyHex',
        '--base=${baseFile.path}',
        '--output=${reconstructedFile.path}',
        '--now=2031-01-01T00:00:00Z',
      ]);
    } finally {
      tempDir.deleteSync(recursive: true);
    }
  });
}

Future<ProcessResult> _runTool(List<String> args) async {
  final packageDir = _packageDir();
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['bin/open_aot_patch_tools.dart', ...args],
    workingDirectory: packageDir.path,
  );
  if (result.exitCode != 0) {
    final output = [
      result.exitCode,
      'stdout:',
      result.stdout,
      'stderr:',
      result.stderr,
    ].join('\n');
    fail('open_aot_patch_tools ${args.join(' ')} failed with $output');
  }
  return result;
}

Future<ProcessResult> _runToolExpectFailure(List<String> args) async {
  final packageDir = _packageDir();
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['bin/open_aot_patch_tools.dart', ...args],
    workingDirectory: packageDir.path,
  );
  if (result.exitCode == 0) {
    fail('open_aot_patch_tools ${args.join(' ')} unexpectedly succeeded');
  }
  return result;
}

Directory _packageDir() {
  final direct = Directory.current;
  if (File('${direct.path}/bin/open_aot_patch_tools.dart').existsSync()) {
    return direct;
  }
  final workspaceMember = Directory(
    '${direct.path}/packages/open_aot_patch_tools',
  );
  final workspaceTool = File(
    '${workspaceMember.path}/bin/open_aot_patch_tools.dart',
  );
  if (workspaceTool.existsSync()) {
    return workspaceMember;
  }
  fail('Unable to locate open_aot_patch_tools package directory.');
}
