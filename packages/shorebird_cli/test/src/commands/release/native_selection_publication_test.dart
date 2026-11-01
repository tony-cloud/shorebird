import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/code_signer.dart';
import 'package:shorebird_cli/src/commands/release/native_selection_publication.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:test/test.dart';

import '../../fixtures/native_selection.dart';
import '../../helpers.dart';
import '../../mocks.dart';

void main() {
  useTempWorkingDirectory();
  late MockCodePushClient client;
  late MockCodePushClientWrapper wrapper;
  late MockArtifactManager manager;
  late MockCodeSigner signer;
  late List<ReleaseArtifact> artifacts;
  late List<Map<String, dynamic>> registrations;
  late Map<int, File> stored;
  const signing = ArtifactSigning(
    mode: 'managed',
    keyId: 7,
    publicKeyPem: 'managed-pem',
  );
  final release = Release(
    id: 1,
    appId: nativeAppId,
    version: nativeVersion,
    selectionProtocol: 2,
    flutterRevision: 'pinned',
    displayName: nativeVersion,
    platforms: const {},
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );
  ReleaseArtifact artifact(
    int id,
    String arch,
    ReleasePlatform platform,
    File file, {
    ArtifactSigning key = signing,
  }) => ReleaseArtifact(
    id: id,
    releaseId: 1,
    arch: arch,
    platform: platform,
    hash: sha256.convert(file.readAsBytesSync()).toString(),
    size: file.lengthSync(),
    url: 'https://storage.invalid/$id',
    canSideload: true,
    signing: key,
  );
  Future<void> verifyPublication(
    ReleasePlatform platform,
    List<String> arches, {
    bool register = true,
  }) => runScoped(
    () => NativeSelectionPublication.verify(
      appId: nativeAppId,
      release: release,
      platform: platform,
      arches: arches,
      expectedNativePatchMaxBytes: null,
      expectedSigningKeyId: 7,
      register: register,
    ),
    values: {
      codePushClientWrapperRef.overrideWith(() => wrapper),
      artifactManagerRef.overrideWith(() => manager),
      codeSignerRef.overrideWith(() => signer),
    },
  );

  setUpAll(() {
    registerFallbackValue(ReleasePlatform.android);
    registerFallbackValue(Uri.parse('https://storage.invalid'));
    registerFallbackValue(
      nativeScopes('android', {'aarch64': nativeElf('aarch64')}).values.single,
    );
  });
  setUp(() {
    client = MockCodePushClient();
    wrapper = MockCodePushClientWrapper();
    manager = MockArtifactManager();
    signer = MockCodeSigner();
    artifacts = [];
    registrations = [];
    stored = {};
    when(() => wrapper.codePushClient).thenReturn(client);
    when(
      () => signer.base64PublicKeyFromPem('managed-pem'),
    ).thenReturn('pinned-key');
    when(
      () => client.getReleaseArtifacts(
        appId: nativeAppId,
        releaseId: 1,
        platform: any(named: 'platform'),
      ),
    ).thenAnswer((_) async => artifacts);
    when(
      () => client.getReleaseSelectionScopes(appId: nativeAppId, releaseId: 1),
    ).thenAnswer((_) async => registrations);
    when(
      () => manager.downloadFile(any(), outputPath: any(named: 'outputPath')),
    ).thenAnswer((invocation) async {
      final uri = invocation.positionalArguments.single as Uri;
      return stored[int.parse(uri.pathSegments.single)]!.copySync(
        invocation.namedArguments[#outputPath] as String,
      );
    });
    when(
      () => client.registerReleaseSelectionScope(
        appId: nativeAppId,
        releaseId: 1,
        scope: any(named: 'scope'),
        releaseArtifactId: any(named: 'releaseArtifactId'),
        supplementArtifactId: any(named: 'supplementArtifactId'),
      ),
    ).thenAnswer((_) async => <String, dynamic>{});
  });

  void android({bool changedAot = false}) {
    final libraries = {
      'arm': nativeElf('arm'),
      'aarch64': nativeElf('aarch64'),
      'x86_64': nativeElf('x86_64'),
    };
    final package = nativePackage('release.aab', libraries: libraries);
    stored[1] = package;
    artifacts.add(artifact(1, 'aab', ReleasePlatform.android, package));
    var id = 1;
    for (final entry in libraries.entries) {
      final file = File('${entry.key}.so')
        ..writeAsBytesSync(
          changedAot ? nativeElf(entry.key, content: 2) : entry.value,
        );
      stored[++id] = file;
      artifacts.add(artifact(id, entry.key, ReleasePlatform.android, file));
    }
  }

  test(
    'registers Android scopes after freshly verifying AAB and separate AOT',
    () async {
      android();
      await verifyPublication(ReleasePlatform.android, [
        'arm',
        'aarch64',
        'x86_64',
      ]);
      verify(
        () => client.registerReleaseSelectionScope(
          appId: nativeAppId,
          releaseId: 1,
          scope: any(named: 'scope'),
          releaseArtifactId: 1,
          supplementArtifactId: null,
        ),
      ).called(3);
      verify(
        () => manager.downloadFile(any(), outputPath: any(named: 'outputPath')),
      ).called(4);
    },
  );
  for (final corruption in [
    'stored bytes',
    'recorded size',
    'separate AOT',
    'managed key',
  ]) {
    test('rejects $corruption before registering any Android scope', () async {
      android(changedAot: corruption == 'separate AOT');
      if (corruption == 'stored bytes') {
        stored[4]!.writeAsBytesSync(nativeElf('x86_64', content: 3));
      }
      if (corruption == 'recorded size') {
        final original = artifacts.removeLast();
        artifacts.add(
          ReleaseArtifact(
            id: original.id,
            releaseId: 1,
            arch: original.arch,
            platform: original.platform,
            hash: original.hash,
            size: original.size + 1,
            url: original.url,
            canSideload: true,
            signing: signing,
          ),
        );
      }
      if (corruption == 'managed key') {
        final original = artifacts.removeLast();
        artifacts.add(
          artifact(
            original.id,
            original.arch,
            original.platform,
            stored[original.id]!,
            key: const ArtifactSigning(
              mode: 'managed',
              keyId: 8,
              publicKeyPem: 'changed',
            ),
          ),
        );
      }
      await expectLater(
        () => verifyPublication(ReleasePlatform.android, [
          'arm',
          'aarch64',
          'x86_64',
        ]),
        throwsFormatException,
      );
      verifyNever(
        () => client.registerReleaseSelectionScope(
          appId: nativeAppId,
          releaseId: 1,
          scope: any(named: 'scope'),
          releaseArtifactId: any(named: 'releaseArtifactId'),
          supplementArtifactId: any(named: 'supplementArtifactId'),
        ),
      );
    });
  }
  for (final platform in [ReleasePlatform.linux, ReleasePlatform.windows]) {
    test(
      'finalizes exact combined x64/ARM64 staged $platform '
      'packages and registrations',
      () async {
        var id = 0;
        for (final arch in ['x86_64', 'aarch64']) {
          final package = nativePackage(
            '$arch.zip',
            platform: platform.name,
            libraries: {arch: nativeElf(arch)},
          );
          stored[++id] = package;
          final prefix = platform == ReleasePlatform.linux
              ? 'bundle'
              : 'win_archive';
          artifacts.add(
            artifact(
              id,
              arch == 'aarch64' ? '${prefix}_aarch64' : prefix,
              platform,
              package,
            ),
          );
          registrations.add({
            'scope': nativeScopes(platform.name, {
              arch: nativeElf(arch),
            })[arch]!.toJson(),
            'release_artifact_id': id,
            'supplement_artifact_id': null,
          });
        }
        await verifyPublication(platform, [
          'x86_64',
          'aarch64',
        ], register: false);
        await expectLater(
          () => verifyPublication(platform, ['x86_64'], register: false),
          throwsFormatException,
        );
        registrations[1]['scope'] = nativeScopes(platform.name, {
          'aarch64': nativeElf('aarch64', content: 2),
        })['aarch64']!.toJson();
        await expectLater(
          () => verifyPublication(platform, [
            'x86_64',
            'aarch64',
          ], register: false),
          throwsFormatException,
        );
      },
    );
  }
  test(
    'optional native supplement is independently retrieved and hash checked',
    () async {
      android();
      final supplement = File('supplement.zip')..writeAsBytesSync([1, 2, 3]);
      stored[5] = supplement;
      artifacts.add(
        artifact(5, 'android_supplement', ReleasePlatform.android, supplement),
      );
      supplement.writeAsBytesSync([4, 5, 6]);
      await expectLater(
        () => verifyPublication(ReleasePlatform.android, [
          'arm',
          'aarch64',
          'x86_64',
        ]),
        throwsFormatException,
      );
      verifyNever(
        () => client.registerReleaseSelectionScope(
          appId: nativeAppId,
          releaseId: 1,
          scope: any(named: 'scope'),
          releaseArtifactId: any(named: 'releaseArtifactId'),
          supplementArtifactId: any(named: 'supplementArtifactId'),
        ),
      );
    },
  );
}
