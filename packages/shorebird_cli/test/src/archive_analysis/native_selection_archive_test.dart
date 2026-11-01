import 'dart:convert';
import 'dart:io';

import 'package:shorebird_cli/src/archive_analysis/native_selection_archive.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';
import 'package:test/test.dart';

import '../fixtures/native_selection.dart';
import '../helpers.dart';

void main() {
  useTempWorkingDirectory();
  Map<String, ReleaseSelectionScope> verify(
    File file,
    String platform,
    List<String> arches, {
    int? budget,
    Map<String, ReleaseSelectionScope>? original,
  }) => NativeSelectionArchive.verify(
    file,
    appId: nativeAppId,
    version: nativeVersion,
    platform: platform,
    arches: arches,
    expectedPublicKey: 'pinned-key',
    expectedNativePatchMaxBytes: budget,
    expectedScopes: original,
  );

  test('measures all three exact final stripped Android AAB libraries', () {
    final libraries = {
      for (final arch in ['arm', 'aarch64', 'x86_64']) arch: nativeElf(arch),
    };
    final file = nativePackage('release.aab', libraries: libraries);
    expect(
      verify(file, 'android', libraries.keys.toList()).keys,
      unorderedEquals(libraries.keys),
    );
    expect(
      NativeSelectionArchive.baselines(file, 'android', libraries.keys),
      libraries,
    );
  });
  for (final platform in ['linux', 'windows']) {
    for (final arch in ['x86_64', 'aarch64']) {
      test('verifies $platform $arch AOT ELF and public scope', () {
        final package = nativePackage(
          'release.zip',
          platform: platform,
          libraries: {arch: nativeElf(arch)},
        );
        final scope = verify(package, platform, [arch])[arch]!;
        expect(scope.runtimeProfile, 'native-aot');
        expect(scope.hostAbiHash, isNull);
      });
    }
  }
  test('rejects incomplete, extra, or wrong-machine final AAB libraries', () {
    final file = nativePackage('release.aab');
    expect(
      () => verify(file, 'android', ['aarch64', 'arm']),
      throwsFormatException,
    );
    final extra = nativePackage(
      'release.aab',
      libraries: {'aarch64': nativeElf('aarch64'), 'arm': nativeElf('arm')},
    );
    expect(() => verify(extra, 'android', ['aarch64']), throwsFormatException);
    final wrong = nativePackage(
      'release.aab',
      libraries: {'aarch64': nativeElf('x86_64')},
    );
    expect(() => verify(wrong, 'android', ['aarch64']), throwsFormatException);
  });
  test('rejects baseline mutation under an unchanged original scope', () {
    final original = nativeScopes('android', {'aarch64': nativeElf('aarch64')});
    final file = nativePackage(
      'release.aab',
      scopes: original,
      libraries: {'aarch64': nativeElf('aarch64', content: 2)},
    );
    expect(() => verify(file, 'android', ['aarch64']), throwsFormatException);
    // A patch keeps original scopes while carrying new AOT bytes.
    expect(verify(file, 'android', ['aarch64'], original: original).keys, [
      'aarch64',
    ]);
  });
  for (final policy in [
    {'patch_verification': 'install_only'},
    {'patch_response_verification': 'optional'},
    {'patch_public_key': 'another-key'},
    {'selection_protocol': 1},
    {'aot_patch_app_build_id': 'another-release'},
    {'aot_patch_runtime_mode': 'dart-bytecode-interpreter'},
    {'native_patch_max_bytes': 100},
  ]) {
    test('rejects changed compiled policy $policy', () {
      expect(
        () => verify(nativePackage('release.aab', policy: policy), 'android', [
          'aarch64',
        ]),
        throwsFormatException,
      );
    });
  }
  test('compares exact native budget including absent policy', () {
    final file = nativePackage(
      'release.aab',
      policy: {'native_patch_max_bytes': 200},
    );
    expect(verify(file, 'android', ['aarch64'], budget: 200), hasLength(1));
    expect(
      () => verify(file, 'android', ['aarch64'], budget: 201),
      throwsFormatException,
    );
    expect(
      () => verify(nativePackage('release.aab'), 'android', [
        'aarch64',
      ], budget: 200),
      throwsFormatException,
    );
  });
  test(
    'rejects measurement packages, extra scopes and private scope fields',
    () {
      expect(
        () => verify(
          nativePackage('release.aab', omitScopes: true),
          'android',
          ['aarch64'],
        ),
        throwsFormatException,
      );
      final extra = nativePackage(
        'release.aab',
        extraMembers: {
          'base/assets/flutter_assets/shorebird_release_scope_android_arm.json':
              utf8.encode('{}'),
        },
      );
      expect(
        () => verify(extra, 'android', ['aarch64']),
        throwsFormatException,
      );
      final scope = nativeScopes('android', {
        'aarch64': nativeElf('aarch64'),
      }).values.single;
      final private = nativePackage(
        'release.aab',
        extraMembers: {
          'base/assets/flutter_assets/${scope.assetName}': utf8.encode(
            jsonEncode({
              ...scope.toJson(),
              'original_baseline_path': '/private/original.so',
            }),
          ),
        },
      );
      expect(
        () => verify(private, 'android', ['aarch64']),
        throwsFormatException,
      );
    },
  );
  test('requires policy and scopes in the actual runtime asset directory', () {
    for (final platform in ['android', 'linux', 'windows']) {
      final file = nativePackage(
        'misplaced.zip',
        platform: platform,
        assetsPrefix: 'docs/flutter_assets',
      );
      expect(() => verify(file, platform, ['aarch64']), throwsFormatException);
    }
  });
  test('rejects duplicate fields in compiled scope JSON', () {
    final scope = nativeScopes('android', {
      'aarch64': nativeElf('aarch64'),
    }).values.single;
    final encoded = jsonEncode(scope.toJson());
    final duplicate = encoded.replaceFirst('{', '{"arch":"aarch64",');
    final file = nativePackage(
      'duplicate.zip',
      extraMembers: {
        'base/assets/flutter_assets/${scope.assetName}': utf8.encode(duplicate),
      },
    );
    expect(() => verify(file, 'android', ['aarch64']), throwsFormatException);
  });

  test('private manifest has exact contract and absolute original paths', () {
    final manifest = NativeSelectionManifest(
      appId: nativeAppId,
      version: nativeVersion,
      platform: 'android',
      arches: ['arm', 'aarch64'],
    );
    try {
      manifest.write();
      final measure =
          jsonDecode(manifest.file.readAsStringSync()) as Map<String, dynamic>;
      expect(
        measure.keys,
        unorderedEquals([
          'version',
          'mode',
          'app_id',
          'release_version',
          'platform',
          'arches',
          'entries',
        ]),
      );
      expect(measure['mode'], 'measure');
      expect(measure['entries'], isEmpty);
      final libraries = {
        'arm': nativeElf('arm'),
        'aarch64': nativeElf('aarch64'),
      };
      manifest.write(
        scopes: nativeScopes('android', libraries),
        baselines: libraries,
      );
      final sealed =
          jsonDecode(manifest.file.readAsStringSync()) as Map<String, dynamic>;
      expect(sealed['mode'], 'sealed');
      for (final entry in sealed['entries'] as List) {
        final value = entry as Map<String, dynamic>;
        expect(
          value.keys,
          unorderedEquals(['scope', 'original_baseline_path']),
        );
        expect((value['scope'] as Map).keys, hasLength(7));
        expect(
          File(value['original_baseline_path'] as String).isAbsolute,
          isTrue,
        );
      }
      expect(
        () => manifest.write(
          scopes: {'arm': nativeScopes('android', libraries)['arm']!},
          baselines: libraries,
        ),
        throwsFormatException,
      );
    } finally {
      manifest.dispose();
    }
    expect(manifest.directory.existsSync(), isFalse);
  });
}
