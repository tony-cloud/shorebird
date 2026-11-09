import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:platform/testing.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_builder/build_trace_session.dart';
import 'package:shorebird_cli/src/cache.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/commands/release/release.dart';
import 'package:shorebird_cli/src/common_arguments.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/flutter_version_constraints.dart';
import 'package:shorebird_cli/src/json_output.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/metadata/metadata.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/release_type.dart';
import 'package:shorebird_cli/src/security_profile.dart';
import 'package:shorebird_cli/src/shorebird_documentation.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_flutter.dart';
import 'package:shorebird_cli/src/shorebird_validator.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/src/base/process.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:test/test.dart';

import '../../helpers.dart';
import '../../matchers.dart';
import '../../mocks.dart';

void main() {
  useTempWorkingDirectory();
  group(ReleaseCommand, () {
    const appId = 'test-app-id';
    const appDisplayName = 'Test App';
    const flutterRevision = '83305b5088e6fe327fb3334a73ff190828d85713';
    const flutterVersionString = '3.22.0';
    final flutterVersion = Version(3, 22, 0);
    const releaseVersion = '1.2.3+1';
    const postReleaseInstructions = 'Make a patch!';
    const artifactDisplayName = 'Amiga app';
    const shorebirdYaml = ShorebirdYaml(appId: appId);
    final appMetadata = AppMetadata(
      appId: appId,
      displayName: appDisplayName,
      createdAt: DateTime(2023),
      updatedAt: DateTime(2023),
    );
    final release = Release(
      id: 0,
      appId: appId,
      version: releaseVersion,
      flutterRevision: flutterRevision,
      flutterVersion: flutterVersionString,
      displayName: '1.2.3+1',
      platforms: const {},
      createdAt: DateTime(2023),
      updatedAt: DateTime(2023),
    );

    late ArgResults argResults;
    late ArtifactBuilder artifactBuilder;
    late Cache cache;
    late CodePushClientWrapper codePushClientWrapper;
    late Directory shorebirdRoot;
    late Directory projectRoot;
    late ShorebirdLogger logger;
    late Progress progress;
    late Releaser releaser;
    late ShorebirdEnv shorebirdEnv;
    late ShorebirdFlutter shorebirdFlutter;
    late ShorebirdValidator shorebirdValidator;
    // Null reads the real toolchain security file under shorebirdRoot.
    late ToolchainSecurity? toolchainFloor;

    late ReleaseCommand command;

    Map<String, String>? platformEnvironment;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        body,
        values: {
          artifactBuilderRef.overrideWith(() => artifactBuilder),
          buildTraceSessionRef.overrideWith(
            () => BuildTraceSession(commandStartedAt: DateTime(2023)),
          ),
          cacheRef.overrideWith(() => cache),
          codePushClientWrapperRef.overrideWith(() => codePushClientWrapper),
          loggerRef.overrideWith(() => logger),
          shorebirdEnvRef.overrideWith(() => shorebirdEnv),
          shorebirdFlutterRef.overrideWith(() => shorebirdFlutter),
          shorebirdValidatorRef.overrideWith(() => shorebirdValidator),
          toolchainSecurityRef.overrideWith(
            () => toolchainFloor ?? ToolchainSecurity.load(shorebirdRoot),
          ),
          if (platformEnvironment case final environment?)
            platformRef.overrideWith(
              () => platformWithEnvironment(environment),
            ),
        },
      );
    }

    setUpAll(() {
      registerFallbackValue(Directory(''));
      registerFallbackValue(release);
      registerFallbackValue(ReleasePlatform.android);
      registerFallbackValue(ReleaseStatus.draft);
      registerFallbackValue(UpdateReleaseMetadata.forTest());
    });

    setUp(() => platformEnvironment = null);

    setUp(() {
      argResults = MockArgResults();
      artifactBuilder = MockArtifactBuilder();
      when(
        () => artifactBuilder.prepareBuildTrace(
          platform: any(named: 'platform'),
        ),
      ).thenAnswer((_) async {});
      when(artifactBuilder.writeBuildTraceSummary).thenReturn(null);
      cache = MockCache();
      codePushClientWrapper = MockCodePushClientWrapper();
      logger = MockShorebirdLogger();
      progress = MockProgress();
      releaser = MockReleaser();
      when(() => releaser.minimumFlutterVersion).thenReturn(Version(0, 0, 0));
      shorebirdRoot = Directory.systemTemp.createTempSync();
      projectRoot = Directory.systemTemp.createTempSync();
      shorebirdEnv = MockShorebirdEnv();
      shorebirdFlutter = MockShorebirdFlutter();
      shorebirdValidator = MockShorebirdValidator();
      toolchainFloor = ToolchainSecurity.legacyToolchain;

      when(() => argResults['dry-run']).thenReturn(false);
      when(() => argResults['platforms']).thenReturn(['android']);
      when(() => argResults['flutter-version']).thenReturn('latest');
      when(
        () => argResults[CommonArguments.patchSigningArg.name],
      ).thenReturn(true);
      when(() => argResults.wasParsed(any())).thenReturn(true);
      when(
        () => argResults.wasParsed(CommonArguments.publicKeyCmd.name),
      ).thenReturn(false);

      when(cache.updateAll).thenAnswer((_) async => {});

      when(
        () => codePushClientWrapper.getApp(appId: any(named: 'appId')),
      ).thenAnswer((_) async => appMetadata);
      when(
        () => codePushClientWrapper.maybeGetRelease(
          appId: any(named: 'appId'),
          releaseVersion: any(named: 'releaseVersion'),
        ),
      ).thenAnswer((_) async => null);
      when(
        () => codePushClientWrapper.createRelease(
          appId: any(named: 'appId'),
          version: any(named: 'version'),
          flutterRevision: any(named: 'flutterRevision'),
          platform: any(named: 'platform'),
        ),
      ).thenAnswer((_) async => release);
      when(
        () => codePushClientWrapper.updateReleaseStatus(
          appId: any(named: 'appId'),
          releaseId: any(named: 'releaseId'),
          platform: any(named: 'platform'),
          status: any(named: 'status'),
          metadata: any(named: 'metadata'),
        ),
      ).thenAnswer((_) async {});

      when(() => logger.progress(any())).thenReturn(progress);

      when(() => releaser.artifactDisplayName).thenReturn(artifactDisplayName);
      when(() => releaser.assertPreconditions()).thenAnswer((_) async => {});
      when(() => releaser.assertArgsAreValid()).thenAnswer((_) async => {});
      when(
        () => releaser.buildReleaseArtifacts(),
      ).thenAnswer((_) async => File(''));
      when(
        () => releaser.getReleaseVersion(
          releaseArtifactRoot: any(named: 'releaseArtifactRoot'),
        ),
      ).thenAnswer((_) async => releaseVersion);
      when(
        () => releaser.uploadReleaseArtifacts(
          release: any(named: 'release'),
          appId: any(named: 'appId'),
        ),
      ).thenAnswer((_) async => {});
      when(
        () => releaser.uploadSupplementArtifact(
          appId: any(named: 'appId'),
          releaseId: any(named: 'releaseId'),
          releaseVersion: any(named: 'releaseVersion'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => releaser.postReleaseInstructions,
      ).thenReturn(postReleaseInstructions);
      when(() => releaser.releaseType).thenReturn(ReleaseType.android);
      when(() => releaser.useObfuscation).thenReturn(false);
      when(
        () => releaser.updatedReleaseMetadata(any()),
      ).thenAnswer((_) async => UpdateReleaseMetadata.forTest());

      when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(shorebirdYaml);
      when(
        () => shorebirdEnv.copyWith(
          flutterRevisionOverride: any(named: 'flutterRevisionOverride'),
        ),
      ).thenAnswer((invocation) {
        when(() => shorebirdEnv.flutterRevision).thenReturn(
          invocation.namedArguments[#flutterRevisionOverride] as String,
        );
        return shorebirdEnv;
      });
      when(() => shorebirdEnv.shorebirdRoot).thenReturn(shorebirdRoot);
      when(
        () => shorebirdEnv.getShorebirdProjectRoot(),
      ).thenReturn(projectRoot);
      when(() => shorebirdEnv.flutterRevision).thenReturn(flutterRevision);
      when(() => shorebirdEnv.usesShorebirdCodePushPackage).thenReturn(true);

      when(
        () => shorebirdFlutter.getVersionAndRevision(),
      ).thenAnswer((_) async => flutterRevision);
      when(
        () =>
            shorebirdFlutter.installRevision(revision: any(named: 'revision')),
      ).thenAnswer((_) async => {});
      when(
        () => shorebirdFlutter.fetchRemoteRefs(),
      ).thenAnswer((_) async {});
      when(
        () => shorebirdFlutter.resolveFlutterVersion(any()),
      ).thenAnswer((_) async => flutterVersion);

      when(
        () => shorebirdValidator.validateFlavors(
          flavorArg: any(named: 'flavorArg'),
          releasePlatform: any(named: 'releasePlatform'),
        ),
      ).thenAnswer((_) async => {});

      command = ReleaseCommand(resolveReleaser: (_) => releaser)
        ..testArgResults = argResults
        ..testRunner = usageRunner();
    });

    test('has non-empty description', () {
      expect(command.description, isNotEmpty);
    });

    test('accepts a hidden --no-confirm and rejects --confirm', () {
      final parser = ReleaseCommand().argParser;
      expect(parser.options['no-confirm']!.hide, isTrue);
      expect(() => parser.parse(['--no-confirm']), returnsNormally);
      expect(
        () => parser.parse(['--confirm']),
        throwsA(isA<FormatException>()),
      );
    });

    group('getReleaser', () {
      test('maps the correct platform to the releaser', () async {
        expect(command.getReleaser(ReleaseType.aar), isA<AarReleaser>());
        expect(
          command.getReleaser(ReleaseType.android),
          isA<AndroidReleaser>(),
        );
        expect(command.getReleaser(ReleaseType.ios), isA<IosReleaser>());
        expect(
          command.getReleaser(ReleaseType.iosFramework),
          isA<IosFrameworkReleaser>(),
        );
        expect(command.getReleaser(ReleaseType.linux), isA<LinuxReleaser>());
        expect(command.getReleaser(ReleaseType.macos), isA<MacosReleaser>());
        expect(
          command.getReleaser(ReleaseType.windows),
          isA<WindowsReleaser>(),
        );
      });
    });

    group('when public key path is provided but no key exists', () {
      setUp(() {
        when(
          () => argResults[CommonArguments.publicKeyArg.name],
        ).thenReturn('/path/to/nonexistent/file');
      });

      test('throws a usage exception naming the flag', () async {
        await expectLater(
          runWithOverrides(command.run),
          throwsA(
            isA<UsageException>().having(
              (e) => e.message,
              'message',
              '--public-key-path: no file found at /path/to/nonexistent/file.',
            ),
          ),
        );

        verifyNever(
          () => codePushClientWrapper.getApp(appId: any(named: 'appId')),
        );
      });
    });

    group('--security-profile', () {
      final toolchainId = 'sha256:${'a' * 64}';
      const releaseRoot = 'eyJjb250cmFjdF92ZXJzaW9uIjoyfQ==';
      final hardenedToolchain = ToolchainSecurity(
        profile: SecurityProfile.hardened,
        toolchainId: toolchainId,
        developmentExceptions: false,
        releaseRoot: releaseRoot,
      );
      const hardenedYaml = ShorebirdYaml(
        appId: appId,
        baseUrl: 'https://updates.example.com',
      );

      void requestProfile(String profile) {
        when(
          () => argResults[ReleaseCommand.securityProfileOption],
        ).thenReturn(profile);
      }

      void expectNothingBuilt() {
        verifyNever(() => releaser.buildReleaseArtifacts());
        verifyNever(
          () => codePushClientWrapper.getApp(appId: any(named: 'appId')),
        );
        verifyNever(
          () => artifactBuilder.securityBuildEnvironment = any(),
        );
        verifyNever(() => releaser.requireManagedSigning = any());
      }

      Future<void> expectRefused(Pattern message) async {
        await expectLater(
          runWithOverrides(command.run),
          throwsA(
            isA<PreconditionFailedExit>().having(
              (e) => e.failure.message,
              'message',
              contains(message),
            ),
          ),
        );
        expectNothingBuilt();
      }

      Future<void> expectUsageError(Pattern message) async {
        await expectLater(
          runWithOverrides(command.run),
          throwsA(
            isA<UsageException>().having(
              (e) => e.message,
              'message',
              contains(message),
            ),
          ),
        );
        expectNothingBuilt();
      }

      test('defaults to legacy and documents the profiles', () {
        final option = ReleaseCommand().argParser.options['security-profile']!;
        expect(option.defaultsTo, 'legacy');
        expect(option.valueHelp, 'legacy|hardened|hardened-diversified');
        expect(
          option.help,
          allOf(
            contains('hardened-diversified is hardened plus'),
            contains('SHOREBIRD_DIVERSIFICATION_PROFILE'),
          ),
        );
      });

      test('rejects an unknown profile', () async {
        requestProfile('strict');
        await expectUsageError(
          'must be legacy, hardened or hardened-diversified, not "strict"',
        );
      });

      group('on a legacy toolchain', () {
        test('legacy release passes no security environment', () async {
          requestProfile('legacy');
          await runWithOverrides(command.run);
          verify(() => releaser.buildReleaseArtifacts()).called(1);
          verifyNever(
            () => artifactBuilder.securityBuildEnvironment = any(),
          );
          verifyNever(() => releaser.requireManagedSigning = any());
        });

        test('refuses a hardened release', () async {
          requestProfile('hardened');
          when(
            () => shorebirdEnv.getShorebirdYaml(),
          ).thenReturn(hardenedYaml);
          await expectRefused('this toolchain was not built hardened');
        });

        test('refuses a hardened-diversified release', () async {
          requestProfile('hardened-diversified');
          when(
            () => shorebirdEnv.getShorebirdYaml(),
          ).thenReturn(hardenedYaml);
          await expectRefused(
            '--security-profile=hardened-diversified needs a '
            'hardened-diversified Shorebird toolchain, but this toolchain '
            'was not built hardened',
          );
        });

        test('refuses a checked-in security key', () async {
          requestProfile('legacy');
          File(
            p.join(projectRoot.path, 'shorebird.yaml'),
          ).writeAsStringSync('app_id: $appId\ntoolchain_id: $toolchainId\n');
          await expectRefused('must not set toolchain_id');
        });
      });

      group('on a development toolchain', () {
        test('refuses a hardened release', () async {
          toolchainFloor = ToolchainSecurity(
            profile: SecurityProfile.hardened,
            toolchainId: toolchainId,
            developmentExceptions: true,
          );
          requestProfile('hardened');
          when(
            () => shorebirdEnv.getShorebirdYaml(),
          ).thenReturn(hardenedYaml);
          await expectRefused('development security exceptions');
        });

        test('refuses a legacy release too', () async {
          toolchainFloor = const ToolchainSecurity(
            profile: SecurityProfile.legacy,
            toolchainId: null,
            developmentExceptions: true,
          );
          requestProfile('legacy');
          await expectRefused('development security exceptions');
        });
      });

      group('when the toolchain security file is invalid', () {
        test('fails closed before building', () async {
          ToolchainSecurity.fileIn(shorebirdRoot)
            ..createSync(recursive: true)
            ..writeAsStringSync('{"schema": 1');
          toolchainFloor = null;
          await expectLater(
            runWithOverrides(command.run),
            throwsA(isA<PreconditionFailedExit>()),
          );
          verify(
            () => logger.err(any(that: contains('not valid JSON'))),
          ).called(1);
          verifyNever(() => releaser.buildReleaseArtifacts());
        });
      });

      group('on a hardened-diversified toolchain', () {
        const interpreterYaml = ShorebirdYaml(
          appId: appId,
          baseUrl: 'https://updates.example.com',
          aotPatchRuntimeMode: 'dart-bytecode-interpreter',
          aotPatchBaseFlavorId: 'free',
          aotPatchBaseLicenseType: 'free',
          aotPatchKeyId: 'app-owned-provider-key',
        );
        late String profilePath;
        late String profileId;

        ToolchainSecurity diversifiedToolchain({
          required String id,
          bool development = false,
        }) => ToolchainSecurity(
          profile: SecurityProfile.hardenedDiversified,
          toolchainId: toolchainId,
          developmentExceptions: development,
          releaseRoot: releaseRoot,
          diversificationProfileId: id,
        );

        setUp(() {
          profilePath = writeDiversificationProfile();
          profileId = BytecodeProfile.load(profilePath).id;
          toolchainFloor = diversifiedToolchain(id: profileId);
          requestProfile('hardened-diversified');
          platformEnvironment = {
            buildManifestSigningKeyEnvironmentVariable:
                writeBuildManifestSigningKey(),
            releaseTrustEnvironmentVariable: writeReleaseTrust(),
            diversificationProfileEnvironmentVariable: profilePath,
          };
          when(
            () => shorebirdEnv.getFlutterProjectRoot(),
          ).thenReturn(projectRoot);
          when(() => releaser.releaseType).thenReturn(ReleaseType.ios);
          // A contract v3 `flutter build` writes a release-record v3.
          when(() => releaser.buildReleaseArtifacts()).thenAnswer((_) async {
            writeReleaseRecord(
              command.releaseRecordDirectory!,
              toolchainId,
              diversificationProfileId: profileId,
            );
            return File('');
          });
          when(
            () => argResults.wasParsed(CommonArguments.publicKeyArg.name),
          ).thenReturn(false);
          when(
            () => argResults.wasParsed(CommonArguments.publicKeyCmd.name),
          ).thenReturn(false);
          when(
            () => shorebirdEnv.getShorebirdYaml(),
          ).thenReturn(interpreterYaml);
          when(
            () => shorebirdEnv.artifactOrigins,
          ).thenReturn((mode: ArtifactOriginMode.split, mirrorUrl: null));
        });

        test('admits an iOS interpreter release, passes the diversified '
            'variables and the profile, and stores the v3 record', () async {
          await runWithOverrides(command.run);
          verify(() => releaser.requireManagedSigning = true).called(1);
          verify(
            () => artifactBuilder.securityBuildEnvironment = {
              'SHOREBIRD_SECURITY_PROFILE': 'hardened-diversified',
              'SHOREBIRD_TOOLCHAIN_ID': toolchainId,
              'SHOREBIRD_RELEASE_ROOT': releaseRoot,
              'SHOREBIRD_RELEASE_MIN_DELEGATIONS_VERSION': '1',
              'SHOREBIRD_DIVERSIFICATION_PROFILE_ID': profileId,
              'SHOREBIRD_BUILD_MANIFEST_RECORD_DIR':
                  command.releaseRecordDirectory!.path,
            },
          ).called(1);
          final profile =
              verify(
                    () => artifactBuilder.bytecodeProfile = captureAny(),
                  ).captured.single
                  as BytecodeProfile;
          expect(profile.id, profileId);
          expect(profile.path, p.absolute(profilePath));
          verify(() => releaser.buildReleaseArtifacts()).called(1);
          final metadata =
              verify(
                    () => releaser.updatedReleaseMetadata(captureAny()),
                  ).captured.single
                  as UpdateReleaseMetadata;
          final record = metadata.securityRecord!;
          expect(record['contract_version'], 3);
          expect(record['security_profile'], 'hardened-diversified');
          expect(record['diversification_profile_id'], profileId);
          expect(metadata.toJson()['security_record'], record);
        });

        test('admits an iOS framework interpreter release', () {
          when(
            () => releaser.releaseType,
          ).thenReturn(ReleaseType.iosFramework);
          runWithOverrides(
            () => command.assertSecurityProfileAdmitted(releaser),
          );
          verify(() => artifactBuilder.bytecodeProfile = any()).called(1);
        });

        test('admits a macOS full replacement interpreter release', () {
          when(() => releaser.releaseType).thenReturn(ReleaseType.macos);
          when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(
            ShorebirdYaml.fromJson({
              ...interpreterYaml.toJson(),
              'aot_patch_full_replacement': true,
            }),
          );
          runWithOverrides(
            () => command.assertSecurityProfileAdmitted(releaser),
          );
          verify(() => artifactBuilder.bytecodeProfile = any()).called(1);
        });

        test('stops before activation when the build wrote a v2 '
            'record', () async {
          when(() => releaser.buildReleaseArtifacts()).thenAnswer((_) async {
            writeReleaseRecord(command.releaseRecordDirectory!, toolchainId);
            return File('');
          });
          await expectLater(
            runWithOverrides(command.run),
            throwsA(
              isA<PreconditionFailedExit>().having(
                (e) => e.failure.message,
                'message',
                contains('is not a contract v3 release record'),
              ),
            ),
          );
          verifyNever(
            () => releaser.uploadReleaseArtifacts(
              release: any(named: 'release'),
              appId: any(named: 'appId'),
            ),
          );
        });

        group('refuses a non-interpreter release', () {
          final cases = <String, void Function()>{
            'android': () => when(
              () => releaser.releaseType,
            ).thenReturn(ReleaseType.android),
            'linux': () => when(
              () => releaser.releaseType,
            ).thenReturn(ReleaseType.linux),
            'windows': () => when(
              () => releaser.releaseType,
            ).thenReturn(ReleaseType.windows),
            'iOS without aot_patch_runtime_mode': () => when(
              () => shorebirdEnv.getShorebirdYaml(),
            ).thenReturn(hardenedYaml),
            'iOS with aot_patch_runtime_mode: ios-aot-link': () =>
                when(
                  () => shorebirdEnv.getShorebirdYaml(),
                ).thenReturn(
                  ShorebirdYaml.fromJson({
                    ...interpreterYaml.toJson(),
                    'aot_patch_runtime_mode': 'ios-aot-link',
                  }),
                ),
            'iOS overridden to native-aot': () => platformEnvironment = {
              ...platformEnvironment!,
              'SHOREBIRD_IOS_PATCH_RUNTIME_MODE': 'native-aot',
            },
            'macOS without full replacement': () => when(
              () => releaser.releaseType,
            ).thenReturn(ReleaseType.macos),
          };
          for (final MapEntry(key: name, value: configure) in cases.entries) {
            test(name, () async {
              configure();
              await expectRefused('needs a bytecode interpreter release');
            });
          }
        });

        test('refuses without SHOREBIRD_DIVERSIFICATION_PROFILE', () async {
          platformEnvironment = {
            ...platformEnvironment!,
            diversificationProfileEnvironmentVariable: '',
          };
          await expectRefused('Set SHOREBIRD_DIVERSIFICATION_PROFILE');
        });

        test('refuses a file that is not a profile', () async {
          platformEnvironment = {
            ...platformEnvironment!,
            diversificationProfileEnvironmentVariable: (File(
              p.join(Directory.systemTemp.createTempSync().path, 'p.json'),
            )..writeAsStringSync('{"schema": 1}')).path,
          };
          await expectRefused('is not a diversification profile');
        });

        test('refuses a profile the toolchain was not built with', () async {
          toolchainFloor = diversifiedToolchain(id: 'sha256:${'d' * 64}');
          await expectRefused(
            'but this toolchain was built with sha256:${'d' * 64}',
          );
        });

        test('refuses the DEVELOPMENT-ONLY profile on a production '
            'toolchain', () async {
          toolchainFloor = diversifiedToolchain(
            id: developmentDiversificationProfileId,
          );
          platformEnvironment = {
            ...platformEnvironment!,
            diversificationProfileEnvironmentVariable:
                developmentDiversificationProfilePath,
          };
          await expectRefused('DEVELOPMENT-ONLY');
        });

        test('refuses a development toolchain', () async {
          toolchainFloor = diversifiedToolchain(
            id: developmentDiversificationProfileId,
            development: true,
          );
          platformEnvironment = {
            ...platformEnvironment!,
            diversificationProfileEnvironmentVariable:
                developmentDiversificationProfilePath,
          };
          await expectRefused('development security exceptions');
        });

        test('still applies every hardened refusal', () async {
          platformEnvironment = {
            ...platformEnvironment!,
            releaseTrustEnvironmentVariable: '',
          };
          await expectRefused('cannot sign its build manifest');
          platformEnvironment = {
            ...platformEnvironment!,
            releaseTrustEnvironmentVariable: writeReleaseTrust(),
          };
          when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(
            ShorebirdYaml.fromJson({
              ...interpreterYaml.toJson(),
              'base_url': 'http://updates.example.com',
            }),
          );
          await expectRefused('must use https');
        });

        test('refuses a hardened release', () async {
          requestProfile('hardened');
          await expectRefused(
            'This Shorebird toolchain is hardened-diversified ($toolchainId), '
            'so it cannot build a hardened release.',
          );
        });

        test('refuses a legacy release', () async {
          requestProfile('legacy');
          await expectRefused('cannot build a legacy release');
          verify(
            () => logger.info(
              any(that: contains('--security-profile=hardened-diversified')),
            ),
          ).called(1);
        });
      });

      group('on a hardened toolchain', () {
        setUp(() {
          toolchainFloor = hardenedToolchain;
          requestProfile('hardened');
          platformEnvironment = {
            buildManifestSigningKeyEnvironmentVariable:
                writeBuildManifestSigningKey(),
            releaseTrustEnvironmentVariable: writeReleaseTrust(),
          };
          when(
            () => shorebirdEnv.getFlutterProjectRoot(),
          ).thenReturn(projectRoot);
          // `flutter build` writes the release record; the mock build does
          // what a contract v2 Flutter does.
          when(() => releaser.buildReleaseArtifacts()).thenAnswer((_) async {
            writeReleaseRecord(command.releaseRecordDirectory!, toolchainId);
            return File('');
          });
          when(
            () => argResults.wasParsed(CommonArguments.publicKeyArg.name),
          ).thenReturn(false);
          when(
            () => argResults.wasParsed(CommonArguments.publicKeyCmd.name),
          ).thenReturn(false);
          when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(hardenedYaml);
          when(
            () => shorebirdEnv.artifactOrigins,
          ).thenReturn((mode: ArtifactOriginMode.split, mirrorUrl: null));
        });

        test('refuses the legacy all-in-one artifact mirror', () async {
          when(() => shorebirdEnv.artifactOrigins).thenReturn((
            mode: ArtifactOriginMode.legacyMirror,
            mirrorUrl: 'http://localhost:8080/download.flutter.io',
          ));
          await expectUsageError(
            'resolve only through the signed artifact catalog',
          );
        });

        test('refuses a legacy release', () async {
          requestProfile('legacy');
          await expectRefused(
            'This Shorebird toolchain is hardened ($toolchainId)',
          );
          verify(
            () => logger.info(
              any(that: contains('--security-profile=hardened')),
            ),
          ).called(1);
        });

        test('never selects hardened by itself', () async {
          when(
            () => argResults[ReleaseCommand.securityProfileOption],
          ).thenReturn(null);
          await expectRefused('cannot build a legacy release');
        });

        test('admits a hardened release with the managed key and an https '
            'base_url and passes exactly the hardened variables', () async {
          // A stale record of an earlier build is never attributed.
          final stale = Directory(
            p.join(projectRoot.path, 'build', 'shorebird', 'release-record'),
          )..createSync(recursive: true);
          File(p.join(stale.path, 'stale.json')).writeAsStringSync('{}');
          await runWithOverrides(command.run);
          verify(() => releaser.requireManagedSigning = true).called(1);
          verify(
            () => artifactBuilder.securityBuildEnvironment = {
              'SHOREBIRD_SECURITY_PROFILE': 'hardened',
              'SHOREBIRD_TOOLCHAIN_ID': toolchainId,
              'SHOREBIRD_RELEASE_ROOT': releaseRoot,
              'SHOREBIRD_RELEASE_MIN_DELEGATIONS_VERSION': '1',
              'SHOREBIRD_BUILD_MANIFEST_RECORD_DIR': stale.path,
            },
          ).called(1);
          verify(() => releaser.buildReleaseArtifacts()).called(1);
          // Hardened builds stay canonical: no diversification profile.
          verifyNever(() => artifactBuilder.bytecodeProfile = any());
          // The release record is stored with the release metadata.
          final metadata =
              verify(
                    () => releaser.updatedReleaseMetadata(captureAny()),
                  ).captured.single
                  as UpdateReleaseMetadata;
          final record = metadata.securityRecord!;
          expect(record['schema'], 'open-shorebird.release-record');
          expect(record['toolchain_id'], toolchainId);
          expect(record['build_manifests'], hasLength(1));
          expect(metadata.toJson()['security_record'], record);
        });

        test('stops before activation when the build wrote no release '
            'record', () async {
          when(
            () => releaser.buildReleaseArtifacts(),
          ).thenAnswer((_) async => File(''));
          await expectLater(
            runWithOverrides(command.run),
            throwsA(
              isA<PreconditionFailedExit>().having(
                (e) => e.failure.message,
                'message',
                contains('wrote no release record'),
              ),
            ),
          );
          // Built, but nothing uploaded and the release never activated.
          verifyNever(
            () => releaser.uploadReleaseArtifacts(
              release: any(named: 'release'),
              appId: any(named: 'appId'),
            ),
          );
        });

        test('refuses a release without a release-trust bundle', () async {
          platformEnvironment = {
            ...platformEnvironment!,
            releaseTrustEnvironmentVariable: '',
          };
          await expectRefused('cannot sign its build manifest');
          verifyNever(() => releaser.buildReleaseArtifacts());
        });

        test('refuses a hardened-diversified release', () async {
          requestProfile('hardened-diversified');
          await expectRefused(
            'This Shorebird toolchain is hardened ($toolchainId), so it '
            'cannot build a hardened-diversified release.',
          );
        });

        test('refuses a release that cannot sign its build manifest', () async {
          for (final environment in <Map<String, String>>[
            {buildManifestSigningKeyEnvironmentVariable: ''},
            {buildManifestSigningKeyEnvironmentVariable: '/no/such/key.pem'},
            {
              buildManifestSigningKeyEnvironmentVariable: (File(
                p.join(Directory.systemTemp.createTempSync().path, 'k'),
              )..writeAsStringSync('not a key')).path,
            },
            {
              ...platformEnvironment!,
              appleTeamIdsEnvironmentVariable: 'ABCDE12345',
            },
          ]) {
            platformEnvironment = {
              buildManifestSigningKeyEnvironmentVariable: '',
              androidSigningCertEnvironmentVariable: '',
              appleTeamIdsEnvironmentVariable: '',
              ...environment,
            };
            await expectRefused('cannot sign its build manifest');
          }
          verifyNever(() => releaser.buildReleaseArtifacts());
        });

        test('admits a declared Android signer certificate', () async {
          platformEnvironment = {
            ...platformEnvironment!,
            androidSigningCertEnvironmentVariable: 'AB:${'CD:' * 30}EF',
          };
          await runWithOverrides(command.run);
          verify(() => releaser.buildReleaseArtifacts()).called(1);
        });

        test('admits selection_protocol 2 with managed signing', () async {
          when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(
            const ShorebirdYaml(
              appId: appId,
              baseUrl: 'https://updates.example.com',
              selectionProtocol: 2,
            ),
          );
          await runWithOverrides(() => command.assertArgsAreValid(releaser));
          verify(() => releaser.requireManagedSigning = true).called(1);
        });

        test('admits --flutter-version naming the pinned revision', () async {
          when(() => argResults['flutter-version']).thenReturn(flutterRevision);
          when(
            () => shorebirdFlutter.resolveFlutterRevision(flutterRevision),
          ).thenAnswer((_) async => flutterRevision);
          await runWithOverrides(command.run);
          verify(() => releaser.buildReleaseArtifacts()).called(1);
        });

        test('refuses another --flutter-version', () async {
          when(() => argResults['flutter-version']).thenReturn('3.22.0');
          await expectUsageError(
            "builds with the installed toolchain's own Flutter "
            '($flutterRevision)',
          );
        });

        test('refuses --public-key-path', () async {
          when(
            () => argResults.wasParsed(CommonArguments.publicKeyArg.name),
          ).thenReturn(true);
          await expectUsageError(
            'uses the Shorebird-managed patch signing key',
          );
        });

        test('refuses --public-key-cmd', () async {
          when(
            () => argResults.wasParsed(CommonArguments.publicKeyCmd.name),
          ).thenReturn(true);
          await expectUsageError(
            'uses the Shorebird-managed patch signing key',
          );
        });

        test('refuses --no-patch-signing', () async {
          when(
            () => argResults[CommonArguments.patchSigningArg.name],
          ).thenReturn(false);
          await expectUsageError('cannot be built with --no-patch-signing');
        });

        test('refuses a checked-in security key', () async {
          File(p.join(projectRoot.path, 'shorebird.yaml')).writeAsStringSync(
            'app_id: $appId\nsecurity_profile: hardened\n',
          );
          await expectRefused('must not set security_profile');
        });

        group('refuses shorebird.yaml', () {
          final cases = <String, (ShorebirdYaml, String)>{
            'without base_url': (
              const ShorebirdYaml(appId: appId),
              'must set base_url',
            ),
            'with an http base_url': (
              const ShorebirdYaml(
                appId: appId,
                baseUrl: 'http://updates.example.com',
              ),
              'must use https',
            ),
            'with an http loopback base_url': (
              const ShorebirdYaml(
                appId: appId,
                baseUrl: 'http://127.0.0.1:8080',
              ),
              'must use https',
            ),
            'with an http localhost base_url': (
              const ShorebirdYaml(
                appId: appId,
                baseUrl: 'http://localhost:8080',
              ),
              'must use https',
            ),
            'with user info in base_url': (
              const ShorebirdYaml(
                appId: appId,
                baseUrl: 'https://user:secret@updates.example.com',
              ),
              'must not contain user info',
            ),
            'with a base_url without a host': (
              const ShorebirdYaml(appId: appId, baseUrl: 'https:///updates'),
              'must name a host',
            ),
            'with patch_verification: install_only': (
              const ShorebirdYaml(
                appId: appId,
                baseUrl: 'https://updates.example.com',
                patchVerification: PatchVerification.installOnly,
              ),
              'patch_verification in shorebird.yaml must be strict',
            ),
            'with patch_response_verification: optional': (
              const ShorebirdYaml(
                appId: appId,
                baseUrl: 'https://updates.example.com',
                patchResponseVerification: PatchResponseVerification.optional,
              ),
              'patch_response_verification in shorebird.yaml must be required',
            ),
          };
          for (final MapEntry(key: name, value: (yaml, message))
              in cases.entries) {
            test(name, () async {
              when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(yaml);
              await expectRefused(message);
            });
          }
        });

        test('admits explicit strict and required verification', () async {
          when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(
            const ShorebirdYaml(
              appId: appId,
              baseUrl: 'https://updates.example.com/api',
              patchVerification: PatchVerification.strict,
              patchResponseVerification: PatchResponseVerification.required,
            ),
          );
          await runWithOverrides(command.run);
          verify(() => releaser.buildReleaseArtifacts()).called(1);
        });
      });
    });

    group('when --build-name is provided and existing release exists', () {
      final existingRelease = Release(
        id: 0,
        appId: appId,
        version: releaseVersion,
        flutterRevision: flutterRevision,
        flutterVersion: flutterVersionString,
        displayName: '1.2.3+1',
        platforms: const {
          ReleasePlatform.android: ReleasePlatformDetails(
            status: ReleaseStatus.active,
          ),
        },
        createdAt: DateTime(2023),
        updatedAt: DateTime(2023),
      );
      setUp(() {
        when(
          () => argResults[CommonArguments.buildNameArg.name],
        ).thenReturn('1.2.3');
        when(
          () => argResults[CommonArguments.buildNumberArg.name],
        ).thenReturn('1');

        when(
          () => codePushClientWrapper.maybeGetRelease(
            appId: appId,
            releaseVersion: releaseVersion,
          ),
        ).thenAnswer((_) async => existingRelease);

        when(
          () => codePushClientWrapper.ensureReleaseIsNotActive(
            release: existingRelease,
            platform: ReleasePlatform.android,
          ),
        ).thenThrow(ProcessExit(ExitCode.software.code));
      });

      test('fails fast instead of building', () async {
        await expectLater(
          () => runWithOverrides(command.run),
          exitsWithCode(ExitCode.software),
        );
        verify(
          () => codePushClientWrapper.ensureReleaseIsNotActive(
            release: existingRelease,
            platform: ReleasePlatform.android,
          ),
        ).called(1);
        verifyNever(() => releaser.buildReleaseArtifacts());
      });
    });

    test('executes commands in order, completes successfully', () async {
      final exitCode = await runWithOverrides(command.run);
      expect(exitCode, equals(ExitCode.success.code));

      verifyInOrder([
        releaser.assertPreconditions,
        releaser.assertArgsAreValid,
        () => shorebirdValidator.validateFlavors(
          flavorArg: null,
          releasePlatform: ReleasePlatform.android,
        ),
        cache.updateAll,
        () => codePushClientWrapper.getApp(appId: appId),
        () => logger.info(
          'Building $artifactDisplayName with Flutter $flutterRevision',
        ),
        () => releaser.buildReleaseArtifacts(),
        () => releaser.getReleaseVersion(
          releaseArtifactRoot: any(named: 'releaseArtifactRoot'),
        ),
        () => releaser.uploadReleaseArtifacts(release: release, appId: appId),
        () => releaser.uploadSupplementArtifact(
          appId: appId,
          releaseId: release.id,
          releaseVersion: release.version,
        ),
        () => logger.success('''

✅ Published Release ${release.version}!'''),
        () => logger.info(postReleaseInstructions),
        () => logger.info(
          '''To create a patch for this release, run ${lightCyan.wrap('shorebird patch --platforms=android --release-version=${release.version}')}''',
        ),
      ]);
    });

    group('when build fails', () {
      setUp(() {
        when(
          () => releaser.buildReleaseArtifacts(),
        ).thenThrow(Exception('oops'));
      });

      test('exits with code 70', () async {
        await expectLater(
          () => runWithOverrides(command.run),
          exitsWithCode(ExitCode.software),
        );
        verify(
          () =>
              logger.err('Failed to build release artifacts: Exception: oops'),
        ).called(1);
      });

      test('passes on an exit that was already reported', () async {
        final exit = ProcessExit(ExitCode.unavailable.code);
        when(() => releaser.buildReleaseArtifacts()).thenThrow(exit);

        await expectLater(
          () => runWithOverrides(command.run),
          throwsA(same(exit)),
        );
        verifyNever(
          () => logger.err(
            any(that: startsWith('Failed to build release artifacts')),
          ),
        );
      });

      group('when failure is an ArtifactBuildException', () {
        late ArtifactBuildException exception;

        setUp(() {
          exception = MockArtifactBuildException();
          when(() => exception.message).thenReturn('oops');
          when(() => releaser.buildReleaseArtifacts()).thenThrow(exception);
        });

        group('when a fix recommendation is provided', () {
          setUp(() {
            when(() => exception.fixRecommendation).thenReturn('fix it');
          });

          test('logs fix recommendation at the info level', () async {
            await expectLater(
              () => runWithOverrides(command.run),
              exitsWithCode(ExitCode.software),
            );
            verify(() => logger.info('fix it')).called(1);
          });
        });
      });
    });

    group('--json', () {
      Future<T> runJson<T>(Future<T> Function() body) => runScoped(
        body,
        values: {isJsonModeRef.overrideWith(() => true)},
      );

      setUp(() {
        when(
          () => codePushClientWrapper.maybeGetRelease(
            appId: any(named: 'appId'),
            releaseVersion: any(named: 'releaseVersion'),
          ),
        ).thenAnswer((_) async => release);
      });

      // The release is already published by the time the refresh runs, so a
      // failure there must not turn a successful run into a failed one --
      // and getRelease, which this used to call, exits the process with a
      // message about publishing patches.
      test(
        'falls back to the release in hand when the refetch fails',
        () async {
          var calls = 0;
          when(
            () => codePushClientWrapper.maybeGetRelease(
              appId: any(named: 'appId'),
              releaseVersion: any(named: 'releaseVersion'),
            ),
          ).thenAnswer((_) async {
            // ensureVersionIsReleasable and getOrCreateRelease each look the
            // version up before the build; the refresh is the one after it.
            if (++calls <= 2) return release;
            throw ProcessExit(ExitCode.software.code);
          });

          final (:exitCode, :json) = await captureJson(
            () => runJson(() => runWithOverrides(command.run)),
          );

          expect(exitCode, equals(ExitCode.success.code));
          expect(json['status'], equals('success'));
          expect(
            (json['data'] as Map<String, dynamic>)['releases'],
            equals([release.toJson()]),
          );
        },
      );

      test('emits the published release, re-fetched after finalize', () async {
        final finalized = Release(
          id: release.id,
          appId: release.appId,
          version: release.version,
          flutterRevision: release.flutterRevision,
          displayName: release.displayName,
          platforms: const {
            ReleasePlatform.android: ReleasePlatformDetails(
              status: ReleaseStatus.active,
            ),
          },
          createdAt: release.createdAt,
          updatedAt: release.updatedAt,
        );
        when(
          () => codePushClientWrapper.maybeGetRelease(
            appId: any(named: 'appId'),
            releaseVersion: any(named: 'releaseVersion'),
          ),
        ).thenAnswer((_) async => finalized);

        final (:exitCode, :json) = await captureJson(
          () => runJson(() => runWithOverrides(command.run)),
        );

        expect(exitCode, equals(ExitCode.success.code));
        expect(json['status'], equals('success'));
        expect(
          json['data'],
          equals({
            'app_id': appId,
            'platforms': ['android'],
            'releases': [finalized.toJson()],
          }),
        );
      });

      test('emits nothing but the envelope on stdout', () async {
        // Human progress lines are still logged; the runner routes them to
        // stderr in JSON mode. Here the logger is a mock, so the check is
        // that the command itself writes only the envelope.
        await captureJson(
          () => runJson(() => runWithOverrides(command.run)),
        );
      });

      group('with --dry-run', () {
        setUp(() {
          when(() => argResults['dry-run']).thenReturn(true);
        });

        test('emits what would have been released', () async {
          final captured = <String>[];
          await expectLater(
            captureStdout(
              () => runJson(() => runWithOverrides(command.run)),
              captured: captured,
            ),
            exitsWithCode(ExitCode.success),
          );

          expect(captured, hasLength(1));
          final envelope = jsonDecode(captured.single) as Map<String, dynamic>;
          expect(envelope['status'], equals('success'));
          expect(
            envelope['data'],
            equals({
              'dry_run': true,
              'app_id': appId,
              'platform': 'android',
              'release_version': release.version,
              'flutter_revision': flutterRevision,
            }),
          );
          verifyNever(() => logger.info('No issues detected.'));
        });
      });
    });

    group('when dry-run is specified', () {
      setUp(() {
        when(() => argResults['dry-run']).thenReturn(true);
      });

      test('does not publish release', () async {
        await expectLater(
          runWithOverrides(command.run),
          exitsWithCode(ExitCode.success),
        );

        verify(() => logger.info('No issues detected.')).called(1);

        verifyNever(
          () => codePushClientWrapper.createRelease(
            appId: appId,
            version: any(named: 'version'),
            flutterRevision: any(named: 'flutterRevision'),
            platform: any(named: 'platform'),
          ),
        );
      });
    });

    group('when flavor and target are provided', () {
      const flavor = 'test-flavor';
      const target = 'test-target';

      setUp(() {
        when(() => argResults['flavor']).thenReturn(flavor);
        when(() => argResults['target']).thenReturn(target);
      });

      test('executes commands in order, completes successfully', () async {
        final exitCode = await runWithOverrides(command.run);
        expect(exitCode, equals(ExitCode.success.code));

        verifyInOrder([
          releaser.assertPreconditions,
          releaser.assertArgsAreValid,
          () => shorebirdValidator.validateFlavors(
            flavorArg: flavor,
            releasePlatform: ReleasePlatform.android,
          ),
          cache.updateAll,
          () => codePushClientWrapper.getApp(appId: appId),
          () => logger.info(
            'Building $artifactDisplayName with Flutter $flutterRevision',
          ),
          () => releaser.buildReleaseArtifacts(),
          () => releaser.getReleaseVersion(
            releaseArtifactRoot: any(named: 'releaseArtifactRoot'),
          ),
          () => releaser.uploadReleaseArtifacts(release: release, appId: appId),
          () => logger.success('''

✅ Published Release ${release.version}!'''),
          () => logger.info(postReleaseInstructions),
          () => logger.info(
            '''To create a patch for this release, run ${lightCyan.wrap('shorebird patch --platforms=android --flavor=$flavor --target=$target --release-version=${release.version}')}''',
          ),
        ]);
      });

      group('when flavor validation fails', () {
        setUp(() {
          when(
            () => shorebirdValidator.validateFlavors(
              flavorArg: any(named: 'flavorArg'),
              releasePlatform: any(named: 'releasePlatform'),
            ),
          ).thenThrow(
            ValidationFailedException(
              message: 'Flavors are not supported on this platform.',
            ),
          );
        });

        test('exits with code 78 (config)', () async {
          await expectLater(
            () => runWithOverrides(command.run),
            exitsWithCode(ExitCode.config),
          );
        });

        test('carries the flavor failure for the runner to report as '
            'precondition_failed', () async {
          await expectLater(
            () => runWithOverrides(command.run),
            throwsA(
              isA<PreconditionFailedExit>().having(
                (e) => e.failure.message,
                'failure.message',
                'Flavors are not supported on this platform.',
              ),
            ),
          );
        });
      });
    });

    group('when there is an existing release with the same version', () {
      late Release existingRelease;
      setUp(() {
        existingRelease = release;
        when(
          () => codePushClientWrapper.maybeGetRelease(
            appId: appId,
            releaseVersion: releaseVersion,
          ),
        ).thenAnswer((_) async => existingRelease);
      });

      group('when the release uses a different version of Flutter', () {
        setUp(() {
          existingRelease = Release(
            id: 0,
            appId: appId,
            version: releaseVersion,
            flutterRevision: 'different',
            flutterVersion: '3.12.1',
            displayName: '1.2.3+1',
            platforms: const {},
            createdAt: DateTime(2023),
            updatedAt: DateTime(2023),
          );

          when(
            () => shorebirdFlutter.getVersionForRevision(
              flutterRevision: flutterRevision,
            ),
          ).thenAnswer((_) async => flutterVersionString);

          when(
            () => shorebirdFlutter.formatVersion(
              revision: flutterRevision,
              version: flutterVersionString,
            ),
          ).thenReturn('3.12.1');
          when(
            () => shorebirdFlutter.formatVersion(
              revision: existingRelease.flutterRevision,
              version: existingRelease.flutterVersion,
            ),
          ).thenReturn('3.12.1');
        });

        test('logs error and exits with code 70', () async {
          await expectLater(
            () => runWithOverrides(command.run),
            exitsWithCode(ExitCode.software),
          );
        });
      });

      group('when the release uses the same version of Flutter', () {
        test('completes successfully', () async {
          expect(
            await runWithOverrides(command.run),
            equals(ExitCode.success.code),
          );
          verify(
            () => codePushClientWrapper.ensureReleaseIsNotActive(
              release: any(named: 'release'),
              platform: ReleasePlatform.android,
            ),
          ).called(1);
        });
      });
    });

    group('when flutter-version is provided', () {
      const flutterVersion = '3.16.3';
      setUp(() {
        when(() => argResults['flutter-version']).thenReturn(flutterVersion);
      });

      test('fetches remote refs before resolving', () async {
        const revision = '771d07b2cf';
        when(
          () => shorebirdFlutter.resolveFlutterRevision(any()),
        ).thenAnswer((_) async => revision);

        await runWithOverrides(command.run);

        verify(() => shorebirdFlutter.fetchRemoteRefs()).called(1);
      });

      group('when unable to determine flutter revision', () {
        final exception = Exception('oops');
        setUp(() {
          when(
            () => shorebirdFlutter.resolveFlutterRevision(any()),
          ).thenThrow(exception);
        });

        test('exits with code 70', () async {
          await expectLater(
            () => runWithOverrides(command.run),
            exitsWithCode(ExitCode.software),
          );
          verify(
            () => logger.err('''
Unable to determine revision for Flutter version: $flutterVersion.
$exception'''),
          ).called(1);
        });
      });

      group('when flutter version is not supported', () {
        setUp(() {
          when(
            () => shorebirdFlutter.resolveFlutterRevision(any()),
          ).thenAnswer((_) async => null);
        });

        test('exits with code 70', () async {
          await expectLater(
            () => runWithOverrides(command.run),
            exitsWithCode(ExitCode.software),
          );
          verify(
            () => logger.err(
              any(that: contains('Version $flutterVersion not found.')),
            ),
          ).called(1);
        });
      });

      group('when flutter version is supported', () {
        const revision = '771d07b2cf';
        setUp(() {
          when(
            () => shorebirdFlutter.resolveFlutterRevision(any()),
          ).thenAnswer((_) async => revision);
        });

        test('uses specified flutter version to build '
            'and reverts to original flutter version', () async {
          when(() => releaser.buildReleaseArtifacts()).thenAnswer((_) async {
            // Ensure we're using the correct flutter version.
            expect(shorebirdEnv.flutterRevision, equals(revision));
            return File('');
          });

          await runWithOverrides(command.run);

          verify(
            () => shorebirdFlutter.installRevision(revision: revision),
          ).called(1);
        });

        group('when flutter version install fails', () {
          setUp(() {
            when(
              () => shorebirdFlutter.installRevision(
                revision: any(named: 'revision'),
              ),
            ).thenThrow(Exception('oops'));
          });

          test('logs the error and exits with code 70', () async {
            await expectLater(
              () => runWithOverrides(command.run),
              exitsWithCode(ExitCode.software),
            );
            verify(
              () => shorebirdFlutter.installRevision(revision: revision),
            ).called(1);
            verify(
              () => logger.err(
                any(
                  that: allOf(
                    contains('Unable to install Flutter $revision.'),
                    contains('Exception: oops'),
                  ),
                ),
              ),
            ).called(1);
          });
        });
      });
    });

    /// Shared expectations for the `--flutter-version` values that ask the
    /// user's toolchain which Flutter version to build with.
    void testFlutterVersionAlias({
      required String arg,
      required String versionCommand,
      required Future<String?> Function() Function() getVersion,
    }) {
      group('when flutter-version is "$arg"', () {
        const reportedVersion = '3.32.4';
        const revision = '771d07b2cf';

        setUp(() {
          when(() => argResults['flutter-version']).thenReturn(arg);
          when(
            () => shorebirdFlutter.resolveFlutterRevision(any()),
          ).thenAnswer((_) async => revision);
        });

        test('builds with the Shorebird revision for the reported '
            'version', () async {
          when(getVersion()).thenAnswer((_) async => reportedVersion);

          await runWithOverrides(command.run);

          // The reported version is looked up like any other version, so we
          // still build with Shorebird's Flutter fork rather than the user's.
          verify(
            () => shorebirdFlutter.resolveFlutterRevision(reportedVersion),
          ).called(1);
          verify(
            () => shorebirdFlutter.installRevision(revision: revision),
          ).called(1);
          verify(
            () => logger.info(
              'Using Flutter $reportedVersion, as reported by '
              '`$versionCommand`.',
            ),
          ).called(1);
        });

        test('only asks for the version once', () async {
          when(getVersion()).thenAnswer((_) async => reportedVersion);

          await runWithOverrides(command.run);

          verify(getVersion()).called(1);
        });

        group('when the version lookup fails', () {
          final exception = Exception('oops');
          setUp(() {
            when(getVersion()).thenThrow(exception);
          });

          test('exits with code 70', () async {
            await expectLater(
              () => runWithOverrides(command.run),
              exitsWithCode(ExitCode.software),
            );
            verify(
              () => logger.err('''
Unable to determine the Flutter version from `$versionCommand`.
$exception'''),
            ).called(1);
          });
        });

        group('when the version cannot be parsed', () {
          setUp(() {
            when(getVersion()).thenAnswer((_) async => null);
          });

          test('exits with code 70', () async {
            await expectLater(
              () => runWithOverrides(command.run),
              exitsWithCode(ExitCode.software),
            );
            verify(
              () => logger.err(
                'Unable to parse a Flutter version from the output of '
                '`$versionCommand`.',
              ),
            ).called(1);
          });
        });
      });
    }

    testFlutterVersionAlias(
      arg: 'system',
      versionCommand: 'flutter --version',
      getVersion: () => shorebirdFlutter.getSystemVersion,
    );

    testFlutterVersionAlias(
      arg: 'fvm',
      versionCommand: 'fvm',
      getVersion: () => shorebirdFlutter.getFvmVersion,
    );

    group('when a patch signing public key is provided', () {
      const keyName = 'test-key-path.pem';
      group('when the key exists', () {
        setUp(() {
          final file = File(
            p.join(Directory.systemTemp.createTempSync().path, keyName),
          )..writeAsStringSync('KEY');
          when(
            () => argResults[CommonArguments.publicKeyArg.name],
          ).thenReturn(file.path);
          when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(
            const ShorebirdYaml(
              appId: appId,
              patchResponseVerification: PatchResponseVerification.optional,
            ),
          );
        });

        test('completes successfully', () async {
          final exitCode = await runWithOverrides(command.run);
          expect(exitCode, equals(ExitCode.success.code));
        });
      });
    });

    group('patch_verification', () {
      const brokenEngineRevision = '6eae37c3bd60906cfaa3b026b3271b896a76e46f';
      const goodEngineRevision = '145c457f310dc800caa96f163cfde167df18f0da';

      void setUpYaml(PatchVerification? patchVerification) {
        when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(
          ShorebirdYaml(appId: appId, patchVerification: patchVerification),
        );
      }

      group('when install_only is set on an engine where it is broken', () {
        setUp(() {
          setUpYaml(PatchVerification.installOnly);
          when(
            () => shorebirdEnv.shorebirdEngineRevision,
          ).thenReturn(brokenEngineRevision);
        });

        test('refuses the release before building', () async {
          await expectLater(
            () => runWithOverrides(command.run),
            throwsA(
              isA<PreconditionFailedExit>()
                  .having((e) => e.exitCode, 'exitCode', ExitCode.config.code)
                  .having(
                    (e) => e.failure.message,
                    'failure.message',
                    contains('does not check patch signatures'),
                  ),
            ),
          );
          verify(
            () => logger.err(
              any(that: contains('`patch_verification: install_only`')),
            ),
          ).called(1);
          verify(
            () => logger.info(any(that: contains('--flutter-version=3.41.8'))),
          ).called(1);
          verifyNever(() => releaser.buildReleaseArtifacts());
        });
      });

      group('when install_only is set on an engine where it works', () {
        setUp(() {
          setUpYaml(PatchVerification.installOnly);
          when(
            () => shorebirdEnv.shorebirdEngineRevision,
          ).thenReturn(goodEngineRevision);
        });

        test('releases', () async {
          final exitCode = await runWithOverrides(command.run);
          expect(exitCode, equals(ExitCode.success.code));
        });
      });

      group('when strict is set on an engine where install_only is broken', () {
        setUp(() {
          setUpYaml(PatchVerification.strict);
          when(
            () => shorebirdEnv.shorebirdEngineRevision,
          ).thenReturn(brokenEngineRevision);
        });

        test('releases', () async {
          final exitCode = await runWithOverrides(command.run);
          expect(exitCode, equals(ExitCode.success.code));
        });
      });
    });

    group('when no platform argument is provided', () {
      setUp(() {
        when(() => argResults['platforms']).thenReturn(const <String>[]);
        command.testRunner = usageRunner();
      });

      test('throws a usage exception listing the valid platforms', () async {
        await expectLater(
          runWithOverrides(command.run),
          throwsA(
            isA<UsageException>().having(
              (e) => e.message,
              'message',
              '''
No platform was provided.
Valid platforms: aar, android, ios, ios-framework, linux, macos, windows''',
            ),
          ),
        );
      });
    });

    group('when the platform argument is invalid', () {
      setUp(() {
        when(() => argResults.wasParsed('platforms')).thenReturn(false);
        when(() => argResults.arguments).thenReturn(['list']);
        when(() => argResults.rest).thenReturn(['list']);
        command.testRunner = usageRunner(commands: {});
      });

      test('throws a usage exception without a subcommand hint', () async {
        await expectLater(
          runWithOverrides(command.run),
          throwsA(
            isA<UsageException>().having(
              (e) => e.message,
              'message',
              '''
Invalid platform: "list".
Valid platforms: aar, android, ios, ios-framework, linux, macos, windows''',
            ),
          ),
        );
      });
    });

    group('when a version is given as a positional', () {
      void stubArgs(List<String> args) {
        when(() => argResults.wasParsed('platforms')).thenReturn(false);
        when(() => argResults.arguments).thenReturn(args);
        when(() => argResults.rest).thenReturn(args);
      }

      setUp(() {
        command.testRunner = usageRunner();
      });

      test('suggests --build-name and --build-number for android', () async {
        stubArgs(['android', '1.0.0+1']);
        await expectLater(
          runWithOverrides(command.run),
          throwsA(
            isA<UsageException>().having(
              (e) => e.message,
              'message',
              '''
Unexpected argument: "1.0.0+1".
Did you mean --build-name=1.0.0 --build-number=1?''',
            ),
          ),
        );
      });

      test('suggests --build-name alone without a build number', () async {
        stubArgs(['android', '1.0.0']);
        await expectLater(
          runWithOverrides(command.run),
          throwsA(
            isA<UsageException>().having(
              (e) => e.message,
              'message',
              '''
Unexpected argument: "1.0.0".
Did you mean --build-name=1.0.0?''',
            ),
          ),
        );
      });

      test('suggests --release-version for aar', () async {
        stubArgs(['aar', '1.0.0+1']);
        await expectLater(
          runWithOverrides(command.run),
          throwsA(
            isA<UsageException>().having(
              (e) => e.message,
              'message',
              '''
Unexpected argument: "1.0.0+1".
Did you mean --release-version=1.0.0+1?''',
            ),
          ),
        );
      });

      test('suggests --release-version for ios-framework', () async {
        stubArgs(['ios-framework', '1.0.0+1']);
        await expectLater(
          runWithOverrides(command.run),
          throwsA(
            isA<UsageException>().having(
              (e) => e.message,
              'message',
              contains('--release-version=1.0.0+1'),
            ),
          ),
        );
      });
    });

    group('when a .dart target is given as a positional', () {
      setUp(() {
        when(() => argResults.wasParsed('platforms')).thenReturn(false);
        when(() => argResults.wasParsed('target')).thenReturn(false);
        when(
          () => argResults.arguments,
        ).thenReturn(['android', 'lib/main_prod.dart']);
        when(
          () => argResults.rest,
        ).thenReturn(['android', 'lib/main_prod.dart']);
        command.testRunner = usageRunner();
      });

      test('uses it as the target and says so', () {
        expect(
          runWithOverrides(() => command.target),
          equals('lib/main_prod.dart'),
        );
        verify(
          () => logger.info(
            'Using lib/main_prod.dart as the target '
            '(--target lib/main_prod.dart).',
          ),
        ).called(1);
      });

      test('throws a usage exception when --target is also given', () {
        when(() => argResults.wasParsed('target')).thenReturn(true);
        when(() => argResults['target']).thenReturn('lib/main.dart');
        expect(
          () => runWithOverrides(() => command.target),
          throwsA(
            isA<UsageException>().having(
              (e) => e.message,
              'message',
              'Both --target lib/main.dart and the positional '
                  'lib/main_prod.dart name a target. Pass only one.',
            ),
          ),
        );
      });
    });

    group('--patch-signing', () {
      test('is on by default', () {
        expect(
          command.argParser.parse([])[CommonArguments.patchSigningArg.name],
          isTrue,
        );
      });

      test('is turned off by --no-patch-signing', () {
        expect(
          command.argParser.parse([
            '--no-patch-signing',
          ])[CommonArguments.patchSigningArg.name],
          isFalse,
        );
      });
    });

    group('printReleaseSummary', () {
      Future<void> printSummary(ReleaseSigningMode mode) => runWithOverrides(
        () => command.printReleaseSummary(
          app: appMetadata,
          releaseVersion: '1.0.0+1',
          flutterVersion: 'deadbeef',
          releasePlatform: ReleasePlatform.android,
          signing: ArtifactSigningRequest(mode: mode),
        ),
      );

      for (final (mode, description) in [
        (ReleaseSigningMode.managed, 'Shorebird-managed key'),
        (ReleaseSigningMode.customer, 'your key'),
      ]) {
        test('describes $mode patch signing', () async {
          await printSummary(mode);

          verify(
            () => logger.info(
              any(
                that: contains(
                  '🔏 Patch Signing: ${lightCyan.wrap(description)}',
                ),
              ),
            ),
          ).called(1);
        });
      }

      test('says patch signing is off for an unsigned release', () async {
        await printSummary(ReleaseSigningMode.unsigned);

        verify(
          () => logger.info(
            any(that: contains('🔏 Patch Signing: ${yellow.wrap('off')}')),
          ),
        ).called(1);
      });
    });

    test(
      'protocol 2 compiled scope cannot use a different built release version',
      () {
        when(() => releaser.releaseType).thenReturn(ReleaseType.macos);
        when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(
          const ShorebirdYaml(
            appId: appId,
            selectionProtocol: 2,
            aotPatchRuntimeMode: 'dart-bytecode-interpreter',
            aotPatchAppBuildId: '1.0.0+1',
          ),
        );
        expect(
          () => runScoped(
            () => command.assertCompiledReleaseVersion(releaser, '1.0.0+2'),
            values: {shorebirdEnvRef.overrideWith(() => shorebirdEnv)},
          ),
          throwsA(isA<UsageException>()),
        );
        runScoped(
          () => command.assertCompiledReleaseVersion(releaser, '1.0.0+1'),
          values: {shorebirdEnvRef.overrideWith(() => shorebirdEnv)},
        );
      },
    );

    group('assertIosInterpreterReleaseConfiguration', () {
      const baseline = {
        'app_id': appId,
        'aot_patch_runtime_mode': 'dart-bytecode-interpreter',
        'aot_patch_base_flavor_id': 'free',
        'aot_patch_base_license_type': 'free',
        'aot_patch_sdk_hash': 'sdk-hash',
        'aot_patch_base_snapshot_hash':
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        'aot_patch_key_id': 'app-owned-provider-key',
      };
      setUp(() {
        when(() => releaser.releaseType).thenReturn(ReleaseType.ios);
        when(
          () => argResults.wasParsed(CommonArguments.publicKeyArg.name),
        ).thenReturn(false);
        when(
          () => argResults.wasParsed(CommonArguments.publicKeyCmd.name),
        ).thenReturn(false);
        when(
          () => shorebirdEnv.getShorebirdYaml(),
        ).thenReturn(ShorebirdYaml.fromJson(baseline));
      });
      test('macOS requires full profile, explicit ARM64 and managed trust', () {
        when(() => releaser.releaseType).thenReturn(ReleaseType.macos);
        when(() => argResults.wasParsed(any())).thenReturn(false);
        when(
          () => argResults.rest,
        ).thenReturn(['--target-platform=darwin-arm64']);
        final full = {...baseline, 'aot_patch_full_replacement': true};
        when(
          () => shorebirdEnv.getShorebirdYaml(),
        ).thenReturn(ShorebirdYaml.fromJson(full));
        runWithOverrides(
          () => command.assertIosInterpreterReleaseConfiguration(releaser),
        );
        for (final configuration in [
          {...full, 'aot_patch_full_replacement': false},
          {...full, 'aot_patch_structural_updates': true},
          {...full, 'aot_patch_runtime_mode': 'native-aot'},
        ]) {
          when(
            () => shorebirdEnv.getShorebirdYaml(),
          ).thenReturn(
            ShorebirdYaml(
              appId: appId,
              aotPatchRuntimeMode:
                  configuration['aot_patch_runtime_mode']! as String,
              aotPatchFullReplacement:
                  configuration['aot_patch_full_replacement']! as bool,
              aotPatchStructuralUpdates:
                  configuration['aot_patch_structural_updates'] as bool?,
            ),
          );
          expect(
            () => runWithOverrides(
              () => command.assertIosInterpreterReleaseConfiguration(releaser),
            ),
            throwsA(isA<UsageException>()),
          );
        }
        when(
          () => shorebirdEnv.getShorebirdYaml(),
        ).thenReturn(ShorebirdYaml.fromJson(full));
        when(
          () => argResults.wasParsed(CommonArguments.publicKeyArg.name),
        ).thenReturn(true);
        expect(
          () => runWithOverrides(
            () => command.assertIosInterpreterReleaseConfiguration(releaser),
          ),
          throwsA(isA<UsageException>()),
        );
        when(
          () => argResults.wasParsed(CommonArguments.publicKeyArg.name),
        ).thenReturn(false);
        when(() => releaser.useObfuscation).thenReturn(true);
        expect(
          () => runWithOverrides(
            () => command.assertIosInterpreterReleaseConfiguration(releaser),
          ),
          throwsA(isA<UsageException>()),
        );
      });
      test(
        'accepts measured baseline policy without future target restrictions',
        () {
          runWithOverrides(
            () => command.assertIosInterpreterReleaseConfiguration(releaser),
          );
        },
      );
      for (final argument in [
        CommonArguments.publicKeyArg,
        CommonArguments.publicKeyCmd,
      ]) {
        test('rejects customer signing through ${argument.name}', () {
          when(() => argResults.wasParsed(argument.name)).thenReturn(true);
          expect(
            () => runWithOverrides(
              () => command.assertIosInterpreterReleaseConfiguration(releaser),
            ),
            throwsA(
              isA<UsageException>().having(
                (e) => e.message,
                'message',
                contains('require managed signing'),
              ),
            ),
          );
        });
      }
      for (final field in baseline.keys.where(
        (key) => !{
          'app_id',
          'aot_patch_sdk_hash',
          'aot_patch_base_snapshot_hash',
        }.contains(key),
      )) {
        test('rejects missing $field before building', () {
          final config = {...baseline}..remove(field);
          when(
            () => shorebirdEnv.getShorebirdYaml(),
          ).thenReturn(ShorebirdYaml.fromJson(config));
          expect(
            () => runWithOverrides(
              () => command.assertIosInterpreterReleaseConfiguration(releaser),
            ),
            throwsA(
              isA<UsageException>().having(
                (e) => e.message,
                'message',
                contains(field),
              ),
            ),
          );
        });
      }
      test('rejects a native artifact hash with invalid SHA-256 format', () {
        final config = {
          ...baseline,
          'aot_patch_base_snapshot_hash': 'native-path',
        };
        when(
          () => shorebirdEnv.getShorebirdYaml(),
        ).thenReturn(ShorebirdYaml.fromJson(config));
        expect(
          () => runWithOverrides(
            () => command.assertIosInterpreterReleaseConfiguration(releaser),
          ),
          throwsA(
            isA<UsageException>().having(
              (e) => e.message,
              'message',
              contains('64 hexadecimal'),
            ),
          ),
        );
      });
      test('rejects obfuscation before building an interpreter release', () {
        when(() => releaser.useObfuscation).thenReturn(true);
        expect(
          () => runWithOverrides(
            () => command.assertIosInterpreterReleaseConfiguration(releaser),
          ),
          throwsA(
            isA<UsageException>().having(
              (e) => e.message,
              'message',
              contains('Remove --obfuscate'),
            ),
          ),
        );
      });

      test(
        'derives SDK and bytecode hashes when source overrides are absent',
        () {
          final config = {...baseline}
            ..remove('aot_patch_sdk_hash')
            ..remove('aot_patch_base_snapshot_hash');
          when(
            () => shorebirdEnv.getShorebirdYaml(),
          ).thenReturn(ShorebirdYaml.fromJson(config));
          runWithOverrides(
            () => command.assertIosInterpreterReleaseConfiguration(releaser),
          );
        },
      );

      test('leaves native customer signing available', () {
        when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(
          const ShorebirdYaml(
            appId: appId,
            aotPatchRuntimeMode: 'native-aot',
            patchResponseVerification: PatchResponseVerification.optional,
          ),
        );
        when(
          () => argResults.wasParsed(CommonArguments.publicKeyArg.name),
        ).thenReturn(true);
        runWithOverrides(
          () => command.assertIosInterpreterReleaseConfiguration(releaser),
        );
      });
    });

    group('customer native response verification policy', () {
      for (final type in ReleaseType.values) {
        for (final mode in [
          null,
          PatchResponseVerification.required,
          PatchResponseVerification.optional,
        ]) {
          test('${type.cliName}: customer ${mode?.name ?? 'default'}', () {
            when(() => releaser.releaseType).thenReturn(type);
            when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(
              ShorebirdYaml(
                appId: appId,
                aotPatchRuntimeMode: 'native-aot',
                patchResponseVerification: mode,
              ),
            );
            when(
              () => argResults[CommonArguments.publicKeyArg.name],
            ).thenReturn('customer-public.pem');
            if (mode == PatchResponseVerification.optional) {
              runWithOverrides(
                () =>
                    command.assertIosInterpreterReleaseConfiguration(releaser),
              );
            } else {
              expect(
                () => runWithOverrides(
                  () => command.assertIosInterpreterReleaseConfiguration(
                    releaser,
                  ),
                ),
                throwsA(
                  isA<UsageException>().having(
                    (e) => e.message,
                    'message',
                    contains(
                      'require explicit patch_response_verification: optional',
                    ),
                  ),
                ),
              );
            }
          });
        }
      }
      test(
        'customer key commands also require explicit optional responses',
        () {
          when(() => releaser.releaseType).thenReturn(ReleaseType.android);
          when(
            () => argResults[CommonArguments.publicKeyCmd.name],
          ).thenReturn('read-customer-public-key');
          expect(
            () => runWithOverrides(
              () => command.assertIosInterpreterReleaseConfiguration(releaser),
            ),
            throwsA(
              isA<UsageException>().having(
                (error) => error.message,
                'message',
                contains(
                  'require explicit patch_response_verification: optional',
                ),
              ),
            ),
          );
        },
      );

      test('managed native signing retains default required responses', () {
        when(() => releaser.releaseType).thenReturn(ReleaseType.android);
        when(
          () => argResults[CommonArguments.publicKeyArg.name],
        ).thenReturn(null);
        when(
          () => argResults[CommonArguments.publicKeyCmd.name],
        ).thenReturn(null);
        runWithOverrides(
          () => command.assertIosInterpreterReleaseConfiguration(releaser),
        );
      });
    });

    group('assertArgsAreValid', () {
      for (final installOnly in [false, true]) {
        test(
          'macOS encrypted release rejects weakened signing '
          'installOnly=$installOnly',
          () async {
            when(() => releaser.releaseType).thenReturn(ReleaseType.macos);
            when(
              () => argResults.wasParsed(CommonArguments.publicKeyArg.name),
            ).thenReturn(false);
            when(
              () => argResults.wasParsed(CommonArguments.publicKeyCmd.name),
            ).thenReturn(false);
            when(
              () => argResults[CommonArguments.patchSigningArg.name],
            ).thenReturn(installOnly);
            when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(
              ShorebirdYaml(
                appId: appId,
                aotPatchRuntimeMode: 'dart-bytecode-interpreter',
                aotPatchFullReplacement: true,
                patchVerification: installOnly
                    ? PatchVerification.installOnly
                    : PatchVerification.strict,
              ),
            );
            await expectLater(
              () =>
                  runWithOverrides(() => command.assertArgsAreValid(releaser)),
              throwsA(isA<UsageException>()),
            );
          },
        );
      }
      test('calls releaser.assertArgsAreValid', () async {
        final releaser = MockReleaser();
        when(() => releaser.minimumFlutterVersion).thenReturn(Version(0, 0, 0));
        when(() => releaser.useObfuscation).thenReturn(false);
        when(releaser.assertArgsAreValid).thenAnswer((_) async => {});
        await runWithOverrides(() => command.assertArgsAreValid(releaser));
        verify(releaser.assertArgsAreValid).called(1);
      });

      for (final type in [ReleaseType.ios, ReleaseType.iosFramework]) {
        test('rejects unsigned encrypted ${type.cliName} release', () async {
          when(
            () => argResults.wasParsed(CommonArguments.publicKeyArg.name),
          ).thenReturn(false);
          when(
            () => argResults.wasParsed(CommonArguments.publicKeyCmd.name),
          ).thenReturn(false);
          when(
            () => argResults[CommonArguments.patchSigningArg.name],
          ).thenReturn(false);
          when(() => releaser.releaseType).thenReturn(type);
          await expectLater(
            () => runWithOverrides(() => command.assertArgsAreValid(releaser)),
            throwsA(
              isA<UsageException>().having(
                (e) => e.message,
                'message',
                contains('require patch signing'),
              ),
            ),
          );
        });
        test(
          'rejects install_only encrypted ${type.cliName} release',
          () async {
            when(() => releaser.releaseType).thenReturn(type);
            when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(
              const ShorebirdYaml(
                appId: appId,
                patchVerification: PatchVerification.installOnly,
              ),
            );
            await expectLater(
              () =>
                  runWithOverrides(() => command.assertArgsAreValid(releaser)),
              throwsA(
                isA<UsageException>().having(
                  (e) => e.message,
                  'message',
                  contains('patch_verification: strict'),
                ),
              ),
            );
          },
        );
      }

      group('when patch_verification is set', () {
        late Releaser releaser;

        setUp(() {
          when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(
            const ShorebirdYaml(
              appId: appId,
              patchVerification: PatchVerification.strict,
            ),
          );
          when(
            () => argResults.wasParsed(CommonArguments.publicKeyArg.name),
          ).thenReturn(false);
          releaser = MockReleaser();
          when(() => releaser.releaseType).thenReturn(ReleaseType.android);
          when(
            () => releaser.minimumFlutterVersion,
          ).thenReturn(Version(0, 0, 0));
          when(() => releaser.useObfuscation).thenReturn(false);
          when(releaser.assertArgsAreValid).thenAnswer((_) async => {});
        });

        test('warns with --no-patch-signing', () async {
          when(
            () => argResults[CommonArguments.patchSigningArg.name],
          ).thenReturn(false);
          await runWithOverrides(() => command.assertArgsAreValid(releaser));
          verify(
            () => logger.warn(
              'patch_verification is set in shorebird.yaml but '
              '--no-patch-signing builds a release whose patches are '
              'unsigned.\n'
              'patch_verification configuration will have no effect.',
            ),
          ).called(1);
        });

        test('does not warn when patches are signed', () async {
          await runWithOverrides(() => command.assertArgsAreValid(releaser));
          verifyNever(() => logger.warn(any()));
        });
      });

      test('rejects --no-patch-signing with a public key', () async {
        when(
          () => argResults[CommonArguments.patchSigningArg.name],
        ).thenReturn(false);
        when(
          () => argResults.wasParsed(CommonArguments.publicKeyArg.name),
        ).thenReturn(true);
        when(
          () => argResults[CommonArguments.publicKeyArg.name],
        ).thenReturn(null);
        final releaser = MockReleaser();
        await expectLater(
          () => runWithOverrides(() => command.assertArgsAreValid(releaser)),
          throwsA(
            isA<UsageException>().having(
              (e) => e.message,
              'message',
              '--no-patch-signing builds a release whose patches are '
                  'unsigned, so it cannot be combined with '
                  '--public-key-path or --public-key-cmd.',
            ),
          ),
        );
      });

      test('exits with code 64 if flutter version is not supported', () async {
        final releaser = MockReleaser();
        when(
          () => releaser.releaseType,
        ).thenReturn(ReleaseType.iosFramework);
        when(releaser.assertArgsAreValid).thenAnswer((_) async => {});
        final laterFlutterVersion = Version(3, 23, 0);
        expect(laterFlutterVersion, greaterThan(flutterVersion));
        when(
          () => releaser.minimumFlutterVersion,
        ).thenReturn(laterFlutterVersion);
        await expectLater(
          () => runWithOverrides(() => command.assertArgsAreValid(releaser)),
          exitsWithCode(ExitCode.usage),
        );
        verify(
          () => logger.err('''
At least Flutter $laterFlutterVersion is required to release with `ios-framework`.
For more information see: ${supportedFlutterVersionsUrl.toLink()}'''),
        ).called(1);
      });

      group('when obfuscating below the obfuscation map floor', () {
        late MockReleaser releaser;
        final oldFlutterVersion = Version(3, 38, 9);

        setUp(() {
          expect(oldFlutterVersion, lessThan(minimumObfuscationFlutterVersion));
          releaser = MockReleaser();
          when(() => releaser.useObfuscation).thenReturn(true);
          when(
            () => releaser.minimumFlutterVersion,
          ).thenReturn(Version(0, 0, 0));
          when(releaser.assertArgsAreValid).thenAnswer((_) async => {});
          when(
            () => shorebirdFlutter.resolveFlutterVersion(any()),
          ).thenAnswer((_) async => oldFlutterVersion);
        });

        test('exits for iOS, whose patches link against the release', () async {
          when(() => releaser.releaseType).thenReturn(ReleaseType.ios);
          await expectLater(
            () => runWithOverrides(() => command.assertArgsAreValid(releaser)),
            exitsWithCode(ExitCode.unavailable),
          );
          verify(
            () => logger.err(
              'Obfuscation on iOS requires Flutter '
              '$minimumObfuscationFlutterVersion or later '
              '(current: $oldFlutterVersion).',
            ),
          ).called(1);
        });

        test('allows Android, whose patches are complete snapshots', () async {
          when(() => releaser.releaseType).thenReturn(ReleaseType.android);
          await runWithOverrides(() => command.assertArgsAreValid(releaser));
          verify(releaser.assertArgsAreValid).called(1);
        });

        test('checks the --flutter-version target, not the CLI pin', () async {
          when(() => releaser.releaseType).thenReturn(ReleaseType.ios);
          when(() => argResults['flutter-version']).thenReturn('3.38.9');
          await expectLater(
            () => runWithOverrides(() => command.assertArgsAreValid(releaser)),
            exitsWithCode(ExitCode.unavailable),
          );
          verify(() => shorebirdFlutter.resolveFlutterVersion('3.38.9'));
        });

        test('checks the CLI pin when no --flutter-version is given', () async {
          when(() => releaser.releaseType).thenReturn(ReleaseType.ios);
          await expectLater(
            () => runWithOverrides(() => command.assertArgsAreValid(releaser)),
            exitsWithCode(ExitCode.unavailable),
          );
          verify(
            () => shorebirdFlutter.resolveFlutterVersion(flutterRevision),
          );
        });
      });
    });

    group('finalizeRelease', () {
      group('when a public key is provided', () {
        setUp(() {
          when(
            () => argResults.wasParsed(CommonArguments.publicKeyArg.name),
          ).thenReturn(true);
        });

        test('completes successfully', () async {
          await runWithOverrides(
            () => command.finalizeRelease(
              release: release,
              releaser: releaser,
            ),
          );
          verify(
            () => releaser.updatedReleaseMetadata(
              any(
                that: isA<UpdateReleaseMetadata>().having(
                  (metadata) => metadata.includesPublicKey,
                  'includesPublicKey',
                  isTrue,
                ),
              ),
            ),
          ).called(1);
        });
      });

      group('when no public key is provided', () {
        setUp(() {
          when(
            () => argResults.wasParsed(CommonArguments.publicKeyArg.name),
          ).thenReturn(false);
        });

        test('completes successfully', () async {
          await runWithOverrides(
            () => command.finalizeRelease(
              release: release,
              releaser: releaser,
            ),
          );
          verify(
            () => releaser.updatedReleaseMetadata(
              any(
                that: isA<UpdateReleaseMetadata>().having(
                  (metadata) => metadata.includesPublicKey,
                  'includesPublicKey',
                  isFalse,
                ),
              ),
            ),
          ).called(1);
        });
      });
    });
  });
}

/// A file shaped like a contract v2 release-trust bundle (flutter build
/// verifies its signatures; the CLI checks only its shape).
String writeReleaseTrust() {
  final dir = Directory.systemTemp.createTempSync('release-trust');
  return (File(p.join(dir.path, 'release-trust.json'))..writeAsStringSync(
        jsonEncode({
          'schema': 'open-shorebird.release-trust',
          'contract_version': 2,
          'root_chain': <Object>[],
          'delegations': {'payload': '', 'signatures': <Object>[]},
        }),
      ))
      .path;
}

/// What a contract v2 (or, with [diversificationProfileId], v3) `flutter
/// build` writes for one build manifest.
void writeReleaseRecord(
  Directory directory,
  String toolchainId, {
  String? diversificationProfileId,
}) {
  directory.createSync(recursive: true);
  File(
    p.join(directory.path, 'build-manifest-${'a' * 64}.json'),
  ).writeAsStringSync(
    jsonEncode({
      'schema': 'open-shorebird.release-record',
      'contract_version': diversificationProfileId == null ? 2 : 3,
      'security_profile': diversificationProfileId == null
          ? 'hardened'
          : 'hardened-diversified',
      'diversification_profile_id': ?diversificationProfileId,
      'toolchain_id': toolchainId,
      'development_exceptions': false,
      'release_root_sha256': 'sha256:${'1' * 64}',
      'root_version': 1,
      'delegations_version': 1,
      'delegations_sha256': '2' * 64,
      'build_manifests': [
        {
          'manifest_sha256': 'a' * 64,
          'signer_key_id': 'sha256:${'3' * 64}',
          'config_sha256': '4' * 64,
          'modules': <Object>[],
        },
      ],
    }),
  );
}

/// A PKCS#8 PEM Ed25519 build-manifest signing key (hardening P3) in a temp
/// directory, and a platform whose environment names it.
String writeBuildManifestSigningKey() {
  final dir = Directory.systemTemp.createTempSync('manifest-key');
  final der = [
    0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, //
    0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
    ...List.filled(32, 7),
  ];
  return (File(p.join(dir.path, 'manifest.pem'))..writeAsStringSync(
        '-----BEGIN PRIVATE KEY-----\n${base64.encode(der)}\n'
        '-----END PRIVATE KEY-----\n',
      ))
      .path;
}

NativePlatform platformWithEnvironment(Map<String, String> environment) =>
    TestNativePlatform.from(
      NativePlatform.current!,
    ).copyWith(
      environment: {...NativePlatform.current!.environment, ...environment},
    );
