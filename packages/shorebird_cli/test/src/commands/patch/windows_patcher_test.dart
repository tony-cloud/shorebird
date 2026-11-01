import 'dart:io';

import 'package:archive/archive.dart';
import 'package:args/args.dart';
import 'package:mocktail/mocktail.dart';
import 'package:platform/platform.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/abi.dart';
import 'package:shorebird_cli/src/archive_analysis/archive_analysis.dart';
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/commands/commands.dart';
import 'package:shorebird_cli/src/doctor.dart';
import 'package:shorebird_cli/src/executables/executables.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform/platform.dart';
import 'package:shorebird_cli/src/release_type.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/validators/validators.dart';
import 'package:test/test.dart';

import '../../helpers.dart';
import '../../mocks.dart';

// Behavior shared with LinuxPatcher is tested in desktop_patcher_test.dart;
// this file covers only what is specific to Windows.
void main() {
  useTempWorkingDirectory();
  group(WindowsPatcher, () {
    late ArgParser argParser;
    late ArgResults argResults;
    late ArtifactBuilder artifactBuilder;
    late ArtifactManager artifactManager;
    late Directory releaseDirectory;
    late Doctor doctor;
    late Powershell powershell;
    late ShorebirdEnv shorebirdEnv;
    late Windows windows;
    late WindowsPatcher patcher;
    late ShorebirdLogger logger;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        body,
        values: {
          abiRef.overrideWith(() => const TestDesktopAbi()),
          artifactBuilderRef.overrideWith(() => artifactBuilder),
          artifactManagerRef.overrideWith(() => artifactManager),
          doctorRef.overrideWith(() => doctor),
          powershellRef.overrideWith(() => powershell),
          shorebirdEnvRef.overrideWith(() => shorebirdEnv),
          windowsRef.overrideWith(() => windows),
          loggerRef.overrideWith(() => logger),
        },
      );
    }

    setUpAll(() {
      registerFallbackValue(Directory(''));
      registerFallbackValue(File(''));
    });

    setUp(() {
      argParser = MockArgParser();
      argResults = MockArgResults();
      artifactBuilder = MockArtifactBuilder();
      artifactManager = MockArtifactManager();
      releaseDirectory = Directory.systemTemp.createTempSync();
      doctor = MockDoctor();
      powershell = MockPowershell();
      shorebirdEnv = MockShorebirdEnv();
      windows = MockWindows();
      logger = MockShorebirdLogger();
      when(() => logger.progress(any())).thenReturn(MockProgress());

      when(
        () => artifactManager.getWindowsReleaseDirectory(),
      ).thenReturn(releaseDirectory);

      patcher = WindowsPatcher(
        argParser: argParser,
        argResults: argResults,
        flavor: null,
        target: 'lib/main_dev.dart',
      );
    });

    test('requires minimumSupportedWindowsFlutterVersion', () {
      expect(
        patcher.minimumFlutterVersion,
        minimumSupportedWindowsFlutterVersion,
      );
    });

    test('identifies as the windows release type', () {
      expect(patcher.releaseType, ReleaseType.windows);
      expect(
        runWithOverrides(() => patcher.primaryReleaseArtifactArch),
        primaryWindowsReleaseArtifactArch,
      );
      expect(
        runWithOverrides(() => patcher.supplementaryReleaseArtifactArch),
        'windows_supplement',
      );
    });

    test('validates with the windows validators on windows', () {
      final validators = <Validator>[MockValidator()];
      when(() => doctor.windowsCommandValidators).thenReturn(validators);

      expect(runWithOverrides(() => patcher.commandValidators), validators);
      expect(patcher.hostOperatingSystem, NativePlatform.windows);
    });

    test('diffs archives with WindowsArchiveDiffer', () {
      expect(patcher.archiveDiffer, const WindowsArchiveDiffer());
    });

    test('patches data/app.so in the release directory', () {
      expect(runWithOverrides(() => patcher.appDirectory), releaseDirectory);
      expect(patcher.dartLibraryPathSegments, ['data', 'app.so']);
    });

    group('validates archives before extraction', () {
      File archiveWith(String path) {
        final archive = Archive()..addFile(ArchiveFile(path, 1, [1]));
        return File('${releaseDirectory.path}/release.zip')
          ..writeAsBytesSync(ZipEncoder().encode(archive));
      }

      for (final discoverVersion in [true, false]) {
        final operation = discoverVersion ? 'version lookup' : 'patch creation';
        Future<Object?> invoke(File archive) => runWithOverrides(
          () => discoverVersion
              ? patcher.extractReleaseVersionFromArtifact(archive)
              : patcher.createPatchArtifacts(
                  appId: 'app',
                  releaseId: 1,
                  releaseArtifact: archive,
                ),
        );

        test(
          '$operation rejects an invalid asset path before extraction',
          () async {
            final archive = archiveWith('data/flutter_assets/CON.txt');
            await expectLater(invoke(archive), throwsFormatException);
            verifyNever(
              () => artifactManager.extractZip(
                zipFile: any(named: 'zipFile'),
                outputDirectory: any(named: 'outputDirectory'),
              ),
            );
            verifyNever(() => powershell.getProductVersion(any()));
          },
        );

        test('$operation allows a valid archive to reach extraction', () async {
          final archive = archiveWith('data/app.so');
          final reachedExtractor = StateError('mock extractor reached');
          when(
            () => artifactManager.extractZip(
              zipFile: any(named: 'zipFile'),
              outputDirectory: any(named: 'outputDirectory'),
            ),
          ).thenThrow(reachedExtractor);
          await expectLater(invoke(archive), throwsA(same(reachedExtractor)));
          verify(
            () => artifactManager.extractZip(
              zipFile: archive,
              outputDirectory: any(named: 'outputDirectory'),
            ),
          ).called(1);
        });
      }
    });

    group('buildApp', () {
      test('builds the windows app and returns its directory', () async {
        final builtDirectory = Directory('built');
        when(
          () => artifactBuilder.buildWindowsApp(
            target: any(named: 'target'),
            args: any(named: 'args'),
            base64PublicKey: any(named: 'base64PublicKey'),
          ),
        ).thenAnswer((_) async => builtDirectory);

        final directory = await runWithOverrides(
          () => patcher.buildApp(args: ['--foo'], base64PublicKey: 'key'),
        );

        expect(directory, builtDirectory);
        verify(
          () => artifactBuilder.buildWindowsApp(
            target: 'lib/main_dev.dart',
            args: ['--foo'],
            base64PublicKey: 'key',
          ),
        ).called(1);
      });
    });

    group('versionFromAppDirectory', () {
      test("reads the executable's product version", () async {
        const projectName = 'my_app';
        final directory = Directory('release');
        final executable = File('my_app.exe');
        final pubspec = MockPubspec();
        when(() => pubspec.name).thenReturn(projectName);
        when(() => shorebirdEnv.getPubspecYaml()).thenReturn(pubspec);
        when(
          () => windows.findExecutable(
            releaseDirectory: any(named: 'releaseDirectory'),
            projectName: any(named: 'projectName'),
          ),
        ).thenReturn(executable);
        when(
          () => powershell.getProductVersion(any()),
        ).thenAnswer((_) async => '1.2.3');

        final version = await runWithOverrides(
          () => patcher.versionFromAppDirectory(directory),
        );

        expect(version, '1.2.3');
        verify(
          () => windows.findExecutable(
            releaseDirectory: directory,
            projectName: projectName,
          ),
        ).called(1);
        verify(() => powershell.getProductVersion(executable)).called(1);
      });
    });
  });
}
