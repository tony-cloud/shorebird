import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:mocktail/mocktail.dart';
import 'package:open_aot_patch_tools/open_aot_patch_tools.dart';
import 'package:path/path.dart' as p;
import 'package:platform/testing.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/commands/release/release.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/executables/ios_linker.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform.dart' as cli_platform;
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:test/test.dart';

import '../../helpers.dart';
import '../../mocks.dart';

const _head =
    '#osb-link-info 2\n'
    'id\tsnapshot_hash\taaaa\n'
    'id\tfeatures\tproduct arm64 ios\n'
    'meta\ttext_image_size\t4096\n';

void main() {
  useTempWorkingDirectory();
  group('IosReleaser aot-link', () {
    late ArgResults argResults;
    late ArtifactBuilder artifactBuilder;
    late ArtifactManager artifactManager;
    late CodePushClientWrapper codePushClientWrapper;
    late IosLinker iosLinker;
    late ShorebirdLogger logger;
    late ShorebirdEnv shorebirdEnv;
    late TestNativePlatform platform;
    late Directory projectRoot;
    late Directory xcarchive;
    late IosReleaser releaser;
    late Map<String, Object?> options;
    final textSha = sha256.convert(utf8.encode('text')).toString();
    ShorebirdYaml yaml({String mode = runtimeModeIosAotLink, int? protocol}) =>
        ShorebirdYaml(
          appId: 'app',
          aotPatchRuntimeMode: mode,
          selectionProtocol: protocol,
        );

    R runWithOverrides<R>(R Function() body) => runScoped(
      body,
      values: {
        artifactBuilderRef.overrideWith(() => artifactBuilder),
        artifactManagerRef.overrideWith(() => artifactManager),
        codePushClientWrapperRef.overrideWith(() => codePushClientWrapper),
        iosLinkerRef.overrideWith(() => iosLinker),
        loggerRef.overrideWith(() => logger),
        cli_platform.platformRef.overrideWith(() => platform),
        shorebirdEnvRef.overrideWith(() => shorebirdEnv),
      },
    );

    setUpAll(() {
      registerFallbackValue(ReleasePlatform.ios);
      registerFallbackValue(Directory(''));
    });

    setUp(() {
      options = {'patch-signing': true};
      argResults = MockArgResults();
      artifactBuilder = MockArtifactBuilder();
      artifactManager = MockArtifactManager();
      codePushClientWrapper = MockCodePushClientWrapper();
      iosLinker = MockIosLinker();
      logger = MockShorebirdLogger();
      shorebirdEnv = MockShorebirdEnv();
      platform = TestNativePlatform(environment: {});
      projectRoot = Directory.systemTemp.createTempSync();
      xcarchive = Directory(p.join(projectRoot.path, 'build', 'ios', 'archive'))
        ..createSync(recursive: true);

      when(() => argResults.rest).thenReturn([]);
      when(() => argResults.options).thenReturn(['aot-link-dd-max-bytes']);
      when(() => argResults.wasParsed(any())).thenAnswer(
        (i) => options.containsKey(i.positionalArguments.single),
      );
      when(() => argResults[any()]).thenAnswer(
        (i) => options[i.positionalArguments.single as String],
      );
      when(
        () => shorebirdEnv.getShorebirdProjectRoot(),
      ).thenReturn(projectRoot);
      when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(yaml());
      when(() => iosLinker.toolPath).thenReturn('/tools/ios_linker.dart');
      when(
        () => iosLinker.requireToolPath(),
      ).thenReturn('/tools/ios_linker.dart');
      when(() => artifactManager.getXcarchiveDirectory()).thenReturn(xcarchive);
      final app = Directory(
        p.join(xcarchive.path, 'Products', 'Applications', 'Runner.app'),
      );
      when(
        () => artifactManager.getIosAppDirectory(
          xcarchiveDirectory: any(named: 'xcarchiveDirectory'),
        ),
      ).thenReturn(app);
      when(
        () => iosLinker.info(
          base: any(named: 'base'),
          baseLink: any(named: 'baseLink'),
        ),
      ).thenAnswer(
        (_) async => IosSnapshotInfo(
          format: 'macho',
          textSize: 4096,
          textSha256: textSha,
        ),
      );

      // What a release build leaves behind.
      final shorebird = Directory(
        p.join(projectRoot.path, 'build', 'ios', 'shorebird'),
      )..createSync(recursive: true);
      File(p.join(shorebird.path, 'App.link')).writeAsStringSync(_head);
      File(p.join(app.path, 'Frameworks', 'App.framework', 'App'))
        ..createSync(recursive: true)
        ..writeAsStringSync('macho');

      releaser = IosReleaser(argResults: argResults, flavor: null, target: null)
        ..aotLinkKernel = (File(p.join(projectRoot.path, 'app.dill'))
          ..writeAsStringSync('kernel'));
    });

    test('is selected by shorebird.yaml', () {
      expect(runWithOverrides(() => releaser.usesAotLink), isTrue);
      when(
        () => shorebirdEnv.getShorebirdYaml(),
      ).thenReturn(yaml(mode: 'native-aot'));
      expect(runWithOverrides(() => releaser.usesAotLink), isFalse);
    });

    group('assembleAotLinkSupplement', () {
      test(
        'stores the sidecar, kernel and release binary with their hashes',
        () async {
          final dir = await runWithOverrides(
            () => releaser.assembleAotLinkSupplement(),
          );
          // Outside flutter_tools' output directory.
          expect(p.basename(dir.path), 'aot_link');
          expect(dir.path, isNot(contains(p.join('ios', 'shorebird'))));
          final supplement = AotLinkSupplement.verify(dir);
          expect(supplement.releaseTextSha256, textSha);
          expect(supplement.usesDd, isFalse);
          expect(
            supplement.files.keys,
            unorderedEquals(['App.link', 'app.dill', 'App.macho']),
          );
          expect(
            File(p.join(dir.path, 'App.macho')).readAsStringSync(),
            'macho',
          );
        },
      );

      test(
        'includes App.dd and the packages only when DD was enabled',
        () async {
          options['aot-link-dd-max-bytes'] = '10000';
          File(p.join(projectRoot.path, 'pubspec.yaml')).writeAsStringSync(
            'name: my_app\n',
          );
          File(
            p.join(projectRoot.path, 'build', 'ios', 'shorebird', 'App.dd'),
          ).writeAsStringSync('# DD\nfoo\n');
          final dir = await runWithOverrides(
            () => releaser.assembleAotLinkSupplement(),
          );
          final supplement = AotLinkSupplement.verify(dir);
          expect(supplement.usesDd, isTrue);
          expect(supplement.ddMaxBytes, 10000);
          expect(supplement.ddPackages, ['my_app']);
        },
      );

      test(
        'a stale App.dd without DD is an error, not a silent inclusion',
        () async {
          File(
            p.join(projectRoot.path, 'build', 'ios', 'shorebird', 'App.dd'),
          ).writeAsStringSync('stale');
          await expectLater(
            () => runWithOverrides(() => releaser.assembleAotLinkSupplement()),
            throwsA(isA<ProcessExit>()),
          );
          verify(() => logger.err(any(that: contains('stale')))).called(1);
        },
      );

      test('a missing sidecar names the engine as the likely cause', () async {
        File(
          p.join(projectRoot.path, 'build', 'ios', 'shorebird', 'App.link'),
        ).deleteSync();
        await expectLater(
          () => runWithOverrides(() => releaser.assembleAotLinkSupplement()),
          throwsA(isA<ProcessExit>()),
        );
        verify(
          () => logger.err(any(that: contains('engine too old'))),
        ).called(1);
      });
    });

    group('uploadSupplementArtifact', () {
      test(
        'uploads the signed supplement with the release id stamped',
        () async {
          late Directory uploaded;
          when(
            () => codePushClientWrapper.createSupplementReleaseArtifact(
              appId: any(named: 'appId'),
              releaseId: any(named: 'releaseId'),
              platform: any(named: 'platform'),
              supplementDirectoryPath: any(named: 'supplementDirectoryPath'),
              arch: any(named: 'arch'),
              signing: any(named: 'signing'),
            ),
          ).thenAnswer((i) async {
            uploaded = Directory(
              i.namedArguments[#supplementDirectoryPath] as String,
            );
            // Verify while the call is in flight, as the zip step would.
            AotLinkSupplement.verify(uploaded);
          });
          await runWithOverrides(
            () => releaser.uploadSupplementArtifact(
              appId: 'app',
              releaseId: 12,
              releaseVersion: '1.0.0+1',
            ),
          );
          final supplement = AotLinkSupplement.verify(uploaded);
          expect(supplement.releaseId, 12);
          expect(supplement.appBuildId, '1.0.0+1');
          verify(
            () => codePushClientWrapper.createSupplementReleaseArtifact(
              appId: 'app',
              releaseId: 12,
              platform: ReleasePlatform.ios,
              supplementDirectoryPath: uploaded.path,
              arch: 'ios_supplement',
              signing: releaser.signing,
            ),
          ).called(1);
        },
      );
    });

    group('assertArgsAreValid', () {
      setUp(() {
        when(() => argResults['flutter-version']).thenReturn('latest');
      });

      Future<void> run() => runWithOverrides(releaser.assertArgsAreValid);

      test('accepts the default configuration', () async {
        await run();
        verifyNever(() => logger.err(any()));
      });

      for (final entry in {
        'obfuscation': () => options['obfuscate'] = true,
        'a missing ios_linker tool': () =>
            when(() => iosLinker.toolPath).thenReturn(null),
        'unsigned patches': () => options['patch-signing'] = false,
        'selection protocol 2': () => when(
          () => shorebirdEnv.getShorebirdYaml(),
        ).thenReturn(yaml(protocol: 2)),
        'install_only verification': () =>
            when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(
              ShorebirdYaml(
                appId: 'app',
                aotPatchRuntimeMode: runtimeModeIosAotLink,
                patchVerification: PatchVerification.installOnly,
              ),
            ),
      }.entries) {
        test('rejects ${entry.key}', () async {
          entry.value();
          when(
            () => argResults.wasParsed('obfuscate'),
          ).thenReturn(options['obfuscate'] == true);
          when(() => argResults['obfuscate']).thenReturn(options['obfuscate']);
          await expectLater(run, throwsA(isA<ProcessExit>()));
          verify(() => logger.err(any())).called(1);
        });
      }
    });
  });
}
