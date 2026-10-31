import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:mocktail/mocktail.dart';
import 'package:open_aot_patch_tools/open_aot_patch_tools.dart' as open_patch;
import 'package:path/path.dart' as p;
import 'package:platform/testing.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_builder/ios_bytecode_builder.dart';
import 'package:shorebird_cli/src/artifact_builder/ios_replacement_host.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/commands/patch/ios_patcher.dart';
import 'package:shorebird_cli/src/commands/release/releaser.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform.dart' as cli_platform;
import 'package:shorebird_cli/src/platform/platform.dart';
import 'package:shorebird_cli/src/release_type.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_flutter.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:test/test.dart';

import '../helpers.dart';
import '../mocks.dart';

class _MockHostResolver extends Mock implements IosReplacementHostResolver {}

/// Only platform hooks are replaced; release preparation and supplements
/// are real.
class _IosReleaser extends Releaser {
  _IosReleaser({required super.argResults}) : super(flavor: null, target: null);

  @override
  ReleaseType get releaseType => ReleaseType.ios;

  @override
  String get artifactDisplayName => 'iOS app';

  @override
  String get supplementPlatformSubdir => 'ios';

  @override
  String get supplementArtifactArch => 'ios_supplement';

  @override
  String get postReleaseInstructions => '';

  @override
  Future<void> assertArgsAreValid() async {}

  @override
  Future<void> assertPreconditions() async {}

  @override
  Future<FileSystemEntity> buildReleaseArtifacts() =>
      throw UnimplementedError();

  @override
  Future<String> getReleaseVersion({
    required FileSystemEntity releaseArtifactRoot,
  }) async => '1.2.3+4';

  @override
  Future<void> uploadReleaseArtifacts({
    required Release release,
    required String appId,
  }) async {}
}

void main() {
  useTempWorkingDirectory();

  const appId = 'full-replacement-app';
  const releaseVersion = '1.2.3+4';
  const releaseId = 42;
  const keyHex =
      '000102030405060708090a0b0c0d0e0f'
      '101112131415161718191a1b1c1d1e1f';
  const rootUri = 'package:example/main.dart';
  const originalUris = [rootUri, 'package:example/removed.dart'];
  const currentUris = ['package:example/added.dart', rootUri];

  late Directory project;
  late ArtifactBuilder builder;
  late ArtifactManager manager;
  late ShorebirdEnv env;
  late ShorebirdFlutter flutter;
  late ShorebirdLogger logger;
  late _MockHostResolver resolver;
  late IosReplacementHost host;
  late ArgResults args;
  late ShorebirdYaml yaml;
  late _IosReleaser releaser;
  late IosPatcher patcher;
  late Map<String, String> buildEnvironment;
  late List<Invocation> compilations;
  late List<String> events;
  late List<Map<String, String>> nativeEnvironments;
  late open_patch.FullReplacementBundle baseline;
  late open_patch.FullReplacementBundle update;
  late File kernel;
  late File releaseArchive;
  Future<void> Function()? nativeBuild;

  ShorebirdYaml policy({
    bool full = true,
    bool structural = false,
    bool patch = false,
    String? payload,
  }) => ShorebirdYaml(
    appId: appId,
    aotPatchRuntimeMode: open_patch.runtimeModeDartBytecodeInterpreter,
    aotPatchFullReplacement: full,
    aotPatchStructuralUpdates: structural,
    aotPatchBytecodePath: payload,
    aotPatchAppBuildId: patch ? 'source-build-id' : releaseVersion,
    aotPatchSdkHash: 'released-sdk',
    aotPatchKeyId: 'released-key',
    aotPatchBaseFlavorId: 'free',
    aotPatchBaseLicenseType: 'free-license',
    aotPatchFlavorId: patch ? 'pro' : 'released-flavor',
    aotPatchLicenseType: patch ? 'pro-license' : 'released-license',
    aotPatchObfuscationMapHash: patch ? 'source-map' : 'released-map',
  );

  open_patch.FullReplacementBundle bundle({
    required List<int> component,
    open_patch.FullReplacementBundle? released,
    List<String> uris = originalUris,
    List<int>? hostAbi,
    String root = rootUri,
  }) {
    final digest = sha256.convert(component).bytes;
    final baseUris = released?.manifest.baselineUris ?? uris;
    return open_patch.FullReplacementBundle(
      component: component,
      manifest: open_patch.FullReplacementManifest(
        hostAbi:
            hostAbi ??
            [
              for (var i = 0; i < host.hostAbi.length; i += 2)
                int.parse(host.hostAbi.substring(i, i + 2), radix: 16),
            ],
        baselineDigest: released?.manifest.baselineDigest ?? digest,
        currentDigest: digest,
        rootUri: root,
        baselineUris: baseUris,
        currentUris: uris,
        removedUris: baseUris.where((uri) => !uris.contains(uri)).toList(),
      ),
    );
  }

  R scoped<R>(R Function() body) => runScoped(
    body,
    values: {
      artifactBuilderRef.overrideWith(() => builder),
      artifactManagerRef.overrideWith(() => manager),
      iosReplacementHostResolverRef.overrideWith(() => resolver),
      loggerRef.overrideWith(() => logger),
      shorebirdEnvRef.overrideWith(() => env),
      shorebirdFlutterRef.overrideWith(() => flutter),
      cli_platform.platformRef.overrideWith(
        () => TestNativePlatform(
          environment: {
            'SHOREBIRD_AOT_PATCH_KEY_HEX': keyHex,
            'SHOREBIRD_AOT_PATCH_NONCE_HEX': '000102030405060708090a0b',
          },
        ),
      ),
    },
  );

  Directory getSupplement() => Directory(
    p.join(project.path, 'build', 'ios', 'shorebird'),
  );

  Map<String, Object?> readManifest() =>
      (jsonDecode(
                File(
                  p.join(
                    getSupplement().path,
                    IosBytecodeBuilder.manifestFileName,
                  ),
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>();

  File writeCompiledRelease(
    Map<String, Object?> manifest, {
    List<int>? replacementBase,
    String name = 'release.zip',
  }) {
    const assets = 'Runner.app/Frameworks/App.framework/flutter_assets';
    final compiledPolicy = utf8.encode(
      jsonEncode({
        'app_id': appId,
        'aot_patch_runtime_mode': open_patch.runtimeModeDartBytecodeInterpreter,
        'aot_patch_full_replacement': manifest['full_replacement'] ?? false,
        'aot_patch_structural_updates': manifest['structural_updates'],
        'aot_patch_replacement_base': 'shorebird_replacement_base.sbr',
        'aot_patch_host_abi': manifest['host_abi'],
        'aot_patch_sdk_hash': manifest['sdk_hash'],
        'aot_patch_base_snapshot_hash': manifest['base_snapshot_hash'],
        'aot_patch_base_flavor_id': manifest['base_flavor_id'],
        'aot_patch_base_license_type': manifest['base_license_type'],
        'aot_patch_key_id': manifest['key_id'],
        'aot_patch_app_build_id': releaseVersion,
        'patch_verification': 'strict',
        'patch_response_verification': 'required',
        'patch_public_key': 'compiled-public-key',
      }),
    );
    final archive = Archive()
      ..addFile(
        ArchiveFile(
          '$assets/shorebird.yaml',
          compiledPolicy.length,
          compiledPolicy,
        ),
      );
    if (manifest['full_replacement'] == true) {
      final bytes = replacementBase ?? baseline.encode();
      archive.addFile(
        ArchiveFile(
          '$assets/shorebird_replacement_base.sbr',
          bytes.length,
          bytes,
        ),
      );
    }
    return File(p.join(project.path, name))
      ..writeAsBytesSync(ZipEncoder().encode(archive));
  }

  Future<void> release({bool full = true, bool structural = false}) async {
    yaml = policy(full: full, structural: structural);
    await scoped(() => releaser.runReleaseBuild((_, _) async {}));
    final manifest = readManifest()
      ..addAll({'release_id': releaseId, 'app_build_id': releaseVersion});
    File(
      p.join(getSupplement().path, IosBytecodeBuilder.manifestFileName),
    ).writeAsStringSync(jsonEncode(manifest));
    releaseArchive = writeCompiledRelease(manifest);
    patcher.releaseSupplementDirectory = getSupplement();
    yaml = policy(full: full, structural: structural, patch: true);
    compilations.clear();
    events.clear();
    clearInteractions(resolver);
  }

  Future<File> buildPatch() async {
    final archive = await scoped(
      () => patcher.buildPatchArtifact(releaseVersion: releaseVersion),
    );
    addTearDown(() => archive.parent.deleteSync(recursive: true));
    return archive;
  }

  Future<Map<Arch, PatchArtifactBundle>> packagePatch() => scoped(
    () => patcher.createPatchArtifacts(
      appId: appId,
      releaseId: releaseId,
      releaseVersion: releaseVersion,
      releaseArtifact: releaseArchive,
    ),
  );

  setUp(() {
    project = Directory.systemTemp.createTempSync('full-replacement-pipeline');
    addTearDown(() => project.deleteSync(recursive: true));
    builder = MockArtifactBuilder();
    manager = MockArtifactManager();
    env = MockShorebirdEnv();
    flutter = MockShorebirdFlutter();
    logger = MockShorebirdLogger();
    resolver = _MockHostResolver();
    host = IosReplacementHost(
      artifacts: {
        'engine': 'a' * 64,
        'gen_snapshot': 'b' * 64,
        'platform': 'c' * 64,
      },
      toolchainVersion: 'matching-product-toolchain',
      toolchainProvenance: {
        'dartaotruntime': 'd' * 64,
        'dart2bytecode': 'e' * 64,
      },
    );
    baseline = bundle(component: [0x33, 0x43, 0x42, 0x44, 1]);
    update = bundle(
      component: [0x33, 0x43, 0x42, 0x44, 2],
      released: baseline,
      uris: currentUris,
    );
    args = MockArgResults();
    when(() => args.options).thenReturn([]);
    when(() => args.rest).thenReturn(['--dart-define=APP=changed']);
    when(() => args.wasParsed(any())).thenReturn(false);
    when(() => env.getShorebirdProjectRoot()).thenReturn(project);
    when(() => env.getShorebirdYaml()).thenAnswer((_) => yaml);
    when(
      () => env.buildDirectory,
    ).thenReturn(Directory(p.join(project.path, 'build')));
    when(
      () => env.flutterDirectory,
    ).thenReturn(Directory(p.join(project.path, 'flutter')));
    when(() => env.iosPodfileLockHash).thenReturn(null);
    when(() => flutter.refreshVersionMetadata()).thenAnswer((_) async {});
    when(() => flutter.getConfig()).thenReturn({});
    when(() => resolver.resolve()).thenAnswer((_) async => host);
    when(() => logger.progress(any())).thenReturn(MockProgress());
    buildEnvironment = {'PRESERVED': 'original'};
    when(
      () => builder.iosInterpreterBuildEnvironment,
    ).thenAnswer((_) => buildEnvironment);
    when(() => builder.iosInterpreterBuildEnvironment = any()).thenAnswer((
      invocation,
    ) {
      return buildEnvironment =
          invocation.positionalArguments.single as Map<String, String>;
    });
    File(p.join(project.path, 'lib', 'main.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('void main() {}');
    kernel = File(p.join(project.path, 'native', 'app.dill'))
      ..createSync(recursive: true)
      ..writeAsStringSync('mock kernel');
    final xcarchive = Directory(
      p.join(project.path, 'native', 'Runner.xcarchive'),
    )..createSync(recursive: true);
    File(
      p.join(xcarchive.path, 'Info.plist'),
    ).writeAsStringSync('native archive');
    when(() => manager.getXcarchiveDirectory()).thenReturn(xcarchive);
    compilations = [];
    events = [];
    nativeEnvironments = [];
    nativeBuild = null;
    when(
      () => builder.buildDartBytecodeSnapshot(
        inputFilePath: any(named: 'inputFilePath'),
        outFilePath: any(named: 'outFilePath'),
        packageConfigPath: any(named: 'packageConfigPath'),
        dartDefines: any(named: 'dartDefines'),
        experiments: any(named: 'experiments'),
        patchBasePath: any(named: 'patchBasePath'),
        structuralUpdates: any(named: 'structuralUpdates'),
        fullReplacement: any(named: 'fullReplacement'),
        hostAbi: any(named: 'hostAbi'),
      ),
    ).thenAnswer((invocation) async {
      compilations.add(invocation);
      final patch = invocation.namedArguments[#patchBasePath] != null;
      events.add(patch ? 'compile patch' : 'compile baseline');
      final full = invocation.namedArguments[#fullReplacement] == true;
      return File(invocation.namedArguments[#outFilePath] as String)
        ..createSync(recursive: true)
        ..writeAsBytesSync(
          full
              ? (patch ? update : baseline).encode()
              : utf8.encode(patch ? 'legacy update' : 'legacy baseline'),
        );
    });
    when(
      () => builder.buildIpa(
        codesign: any(named: 'codesign'),
        flavor: any(named: 'flavor'),
        target: any(named: 'target'),
        args: any(named: 'args'),
        base64PublicKey: any(named: 'base64PublicKey'),
      ),
    ).thenAnswer((_) async {
      events.add('native');
      nativeEnvironments.add(Map.of(buildEnvironment));
      await nativeBuild?.call();
      return AppleBuildResult(kernelFile: kernel);
    });
    when(
      () => manager.createDiff(
        releaseArtifactPath: any(named: 'releaseArtifactPath'),
        patchArtifactPath: any(named: 'patchArtifactPath'),
      ),
    ).thenAnswer((invocation) async {
      expect(
        File(
          invocation.namedArguments[#releaseArtifactPath] as String,
        ).readAsBytesSync(),
        isEmpty,
      );
      events.add('transport');
      return (File(
        p.join(project.path, 'transport.patch'),
      )..writeAsBytesSync([1, 2, 3])).path;
    });
    yaml = policy();
    releaser = _IosReleaser(argResults: args);
    patcher = IosPatcher(
      argParser: ArgParser(),
      argResults: args,
      flavor: null,
      target: null,
    );
  });

  test(
    'release binds the native host and supplement '
    'to the exact compiled wrapper',
    () async {
      final previous = buildEnvironment;
      final result = await scoped(
        () => releaser.runReleaseBuild((buildArgs, key) async {
          expect(buildArgs, ['--dart-define=APP=changed']);
          expect(buildEnvironment['SHOREBIRD_AOT_HOST_ABI'], host.hostAbi);
          final nativeBase = File(
            buildEnvironment['SHOREBIRD_AOT_REPLACEMENT_BASE']!,
          );
          expect(nativeBase.readAsBytesSync(), baseline.encode());
          expect(
            buildEnvironment['SHOREBIRD_AOT_BASE_SNAPSHOT_HASH'],
            open_patch.sha256Hex(baseline.encode()),
          );
          expect(buildEnvironment['PRESERVED'], 'original');
          return 'native release';
        }),
      );
      expect(result, 'native release');
      expect(buildEnvironment, same(previous));
      verify(() => resolver.resolve()).called(1);
      expect(compilations, hasLength(1));
      final compile = compilations.single.namedArguments;
      expect(compile[#fullReplacement], isTrue);
      expect(compile[#structuralUpdates], isFalse);
      expect(compile[#hostAbi], host.hostAbi);
      expect(compile[#patchBasePath], isNull);
      final manifest = readManifest();
      expect(manifest['full_replacement'], isTrue);
      for (final field in host.manifest.entries) {
        expect(manifest[field.key], field.value, reason: field.key);
      }
      expect(
        manifest['base_snapshot_hash'],
        open_patch.sha256Hex(baseline.encode()),
      );
      expect(
        File(
          p.join(getSupplement().path, IosBytecodeBuilder.baselineFileName),
        ).readAsBytesSync(),
        baseline.encode(),
      );
    },
  );

  test(
    'release native failure restores environment and creates no supplement',
    () async {
      final previous = buildEnvironment;
      final failure = StateError('native release failed');
      await expectLater(
        scoped(
          () => releaser.runReleaseBuild<void>((_, _) async => throw failure),
        ),
        throwsA(same(failure)),
      );
      expect(buildEnvironment, same(previous));
      expect(getSupplement().existsSync(), isFalse);
    },
  );

  test(
    'full patch compiles once before native comparison '
    'and publishes the original-bound update',
    () async {
      await release();
      final previous = buildEnvironment;
      await buildPatch();
      expect(events, ['compile patch', 'native']);
      expect(compilations, hasLength(1));
      final compile = compilations.single.namedArguments;
      expect(compile[#fullReplacement], isTrue);
      expect(compile[#structuralUpdates], isFalse);
      expect(compile[#hostAbi], host.hostAbi);
      expect(
        compile[#patchBasePath],
        p.join(getSupplement().path, IosBytecodeBuilder.baselineFileName),
      );
      verify(() => resolver.resolve()).called(1);
      final native = nativeEnvironments.single;
      final comparisonBytes = File(
        native['SHOREBIRD_AOT_REPLACEMENT_BASE']!,
      ).readAsBytesSync();
      final comparison = open_patch.FullReplacementBundle.decode(
        comparisonBytes,
      );
      expect(comparison.component, update.component);
      expect(comparison.manifest.isBaseline, isTrue);
      expect(comparison.manifest.baselineUris, currentUris);
      expect(comparison.manifest.currentUris, currentUris);
      expect(comparison.manifest.removedUris, isEmpty);
      expect(comparison.manifest.baselineDigest, update.manifest.currentDigest);
      expect(
        native['SHOREBIRD_AOT_BASE_SNAPSHOT_HASH'],
        open_patch.sha256Hex(comparisonBytes),
      );
      expect(
        native['SHOREBIRD_AOT_BASE_SNAPSHOT_HASH'],
        isNot(open_patch.sha256Hex(baseline.encode())),
      );
      expect(native['SHOREBIRD_AOT_HOST_ABI'], host.hostAbi);
      final manifest = readManifest();
      for (final entry in {
        'APP_BUILD_ID': 'compiled_app_build_id',
        'BASE_FLAVOR_ID': 'base_flavor_id',
        'BASE_LICENSE_TYPE': 'base_license_type',
        'SDK_HASH': 'sdk_hash',
        'KEY_ID': 'key_id',
        'FLAVOR_ID': 'flavor_id',
        'LICENSE_TYPE': 'license_type',
        'OBFUSCATION_MAP_HASH': 'obfuscation_map_hash',
      }.entries) {
        expect(
          native['SHOREBIRD_AOT_PATCH_${entry.key}'],
          manifest[entry.value],
          reason: entry.key,
        );
      }
      expect(native['PRESERVED'], 'original');
      expect(buildEnvironment, same(previous));
      expect(patcher.archiveDifferOverride, isNotNull);
      final nativeComparisonArchive = writeCompiledRelease(
        {
          ...manifest,
          'base_snapshot_hash': native['SHOREBIRD_AOT_BASE_SNAPSHOT_HASH'],
        },
        replacementBase: comparisonBytes,
        name: 'comparison.zip',
      );
      final archiveDiff = await scoped(
        () => patcher.archiveDifferOverride!.changedFiles(
          releaseArchive.path,
          nativeComparisonArchive.path,
        ),
      );
      expect(archiveDiff, isEmpty);

      final artifacts = await packagePatch();
      expect(events, ['compile patch', 'native', 'transport']);
      final envelope = File(
        p.join(project.path, 'build', 'ios_interpreter_patch.vmcode'),
      );
      final encrypted = open_patch.EncryptedPatchArtifact.fromJson(
        (jsonDecode(envelope.readAsStringSync()) as Map)
            .cast<String, Object?>(),
      );
      final publishedBytes = encrypted
          .decrypt(open_patch.readKey(keyHex))
          .reconstruct(const []);
      expect(publishedBytes, update.encode());
      final published = open_patch.FullReplacementBundle.decode(publishedBytes)
        ..validateUpdateAgainst(baseline);
      expect(published.manifest.baselineUris, originalUris);
      expect(published.manifest.currentUris, currentUris);
      expect(published.manifest.removedUris, ['package:example/removed.dart']);
      expect(published.manifest.isBaseline, isFalse);
      expect(
        encrypted.metadata.baseSnapshotHash,
        open_patch.sha256Hex(baseline.encode()),
      );
      expect(encrypted.metadata.flavorId, 'pro');
      expect(
        artifacts[Arch.arm64]!.hash,
        open_patch.sha256Hex(envelope.readAsBytesSync()),
      );
      expect(compilations, hasLength(1));
    },
  );

  test(
    'native patch failure restores policy and stops before transport creation',
    () async {
      await release();
      final previous = buildEnvironment;
      final failure = StateError('native check failed');
      nativeBuild = () async => throw failure;
      await expectLater(
        () async {
          await buildPatch();
          await packagePatch();
        },
        throwsA(same(failure)),
      );
      expect(events, ['compile patch', 'native']);
      expect(buildEnvironment, same(previous));
      expect(
        File(
          p.join(project.path, 'build', 'ios_interpreter_patch.vmcode'),
        ).existsSync(),
        isFalse,
      );
      verifyNever(
        () => manager.createDiff(
          releaseArtifactPath: any(named: 'releaseArtifactPath'),
          patchArtifactPath: any(named: 'patchArtifactPath'),
        ),
      );
    },
  );

  test(
    'a different native host is rejected before compiler or native build',
    () async {
      await release();
      when(() => resolver.resolve()).thenAnswer(
        (_) async => IosReplacementHost(
          artifacts: {...host.artifacts, 'engine': 'f' * 64},
          toolchainVersion: host.toolchainVersion,
          toolchainProvenance: host.toolchainProvenance,
        ),
      );
      await expectLater(buildPatch(), throwsA(isA<ArtifactBuildException>()));
      expect(events, isEmpty);
      expect(buildEnvironment, {'PRESERVED': 'original'});
    },
  );

  test(
    'a valid configured replacement uses the same comparison and publication '
    'without recompiling',
    () async {
      await release();
      File(
        p.join(project.path, 'external.sbr'),
      ).writeAsBytesSync(update.encode());
      yaml = policy(patch: true, payload: 'external.sbr');
      await buildPatch();
      expect(events, ['native']);
      expect(compilations, isEmpty);
      final comparison = open_patch.FullReplacementBundle.decode(
        File(
          nativeEnvironments.single['SHOREBIRD_AOT_REPLACEMENT_BASE']!,
        ).readAsBytesSync(),
      );
      expect(comparison.manifest.isBaseline, isTrue);
      expect(comparison.manifest.baselineUris, currentUris);
      expect(comparison.component, update.component);
      await packagePatch();
      final envelope = open_patch.EncryptedPatchArtifact.fromJson(
        (jsonDecode(
                  File(
                    p.join(
                      project.path,
                      'build',
                      'ios_interpreter_patch.vmcode',
                    ),
                  ).readAsStringSync(),
                )
                as Map)
            .cast<String, Object?>(),
      );
      expect(
        envelope.decrypt(open_patch.readKey(keyHex)).reconstruct(const []),
        update.encode(),
      );
      expect(compilations, isEmpty);
    },
  );

  for (final mismatch in ['host', 'baseline', 'domain']) {
    test(
      'configured replacement rejects a mismatched $mismatch '
      'before native build or publication',
      () async {
        await release();
        final otherBaseline = bundle(
          component: [
            0x33,
            0x43,
            0x42,
            0x44,
            if (mismatch == 'baseline') 9 else 1,
          ],
          uris: mismatch == 'domain' ? [rootUri] : originalUris,
        );
        final payload = bundle(
          component: update.component,
          released: otherBaseline,
          uris: currentUris,
          hostAbi: mismatch == 'host' ? List.filled(32, 0xff) : null,
        );
        File(
          p.join(project.path, 'external.sbr'),
        ).writeAsBytesSync(payload.encode());
        yaml = policy(patch: true, payload: 'external.sbr');
        await expectLater(buildPatch(), throwsA(isA<FormatException>()));
        await expectLater(packagePatch(), throwsA(isA<FormatException>()));
        expect(events, isEmpty);
        expect(buildEnvironment, {'PRESERVED': 'original'});
      },
    );
  }

  test('source profile cannot downgrade a full replacement release', () async {
    await release();
    yaml = policy(full: false, patch: true, payload: 'external.sbr');
    await expectLater(buildPatch(), throwsA(isA<ArtifactBuildException>()));
    await expectLater(packagePatch(), throwsA(isA<ArtifactBuildException>()));
    expect(events, isEmpty);
    verifyZeroInteractions(resolver);
  });

  for (final structural in [false, true]) {
    test(
      'legacy structural=$structural keeps '
      'the original native-then-bytecode flow',
      () async {
        await release(full: false, structural: structural);
        final previous = buildEnvironment;
        await buildPatch();
        expect(events, ['native', 'compile patch']);
        expect(compilations, hasLength(1));
        final compile = compilations.single.namedArguments;
        expect(compile[#fullReplacement], isFalse);
        expect(compile[#structuralUpdates], structural);
        expect(compile[#hostAbi], isNull);
        expect(
          compile[#patchBasePath],
          p.join(getSupplement().path, IosBytecodeBuilder.baselineFileName),
        );
        expect(
          nativeEnvironments.single.containsKey(
            'SHOREBIRD_AOT_REPLACEMENT_BASE',
          ),
          isFalse,
        );
        expect(
          nativeEnvironments.single['SHOREBIRD_AOT_BASE_SNAPSHOT_HASH'],
          open_patch.sha256Hex(utf8.encode('legacy baseline')),
        );
        expect(buildEnvironment, same(previous));
        expect(patcher.archiveDifferOverride, isNull);
        verifyZeroInteractions(resolver);
        final artifacts = await packagePatch();
        expect(artifacts.keys, [Arch.arm64]);
      },
    );
  }
}
