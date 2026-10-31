import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/cache.dart';
import 'package:shorebird_cli/src/engine_config.dart';
import 'package:shorebird_cli/src/shorebird_artifacts.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:test/test.dart';

import 'helpers.dart';
import 'mocks.dart';

void main() {
  useTempWorkingDirectory();
  group(ShorebirdCachedArtifacts, () {
    const engineRevision = 'engine-revision';
    late Cache cache;
    late Directory flutterDirectory;
    late Directory artifactDirectory;
    late ShorebirdEnv shorebirdEnv;
    late ShorebirdCachedArtifacts artifacts;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        () => body(),
        values: {
          cacheRef.overrideWith(() => cache),
          shorebirdEnvRef.overrideWith(() => shorebirdEnv),
        },
      );
    }

    setUp(() {
      cache = MockCache();
      final tmpDir = Directory.systemTemp.createTempSync();
      flutterDirectory = Directory(p.join(tmpDir.path, 'flutter'))
        ..createSync(recursive: true);
      artifactDirectory = Directory(p.join(tmpDir.path, 'artifacts'))
        ..createSync(recursive: true);
      shorebirdEnv = MockShorebirdEnv();
      artifacts = const ShorebirdCachedArtifacts();

      when(
        () => cache.getArtifactDirectory(any()),
      ).thenReturn(artifactDirectory);
      when(() => shorebirdEnv.flutterDirectory).thenReturn(flutterDirectory);
      when(
        () => shorebirdEnv.shorebirdEngineRevision,
      ).thenReturn(engineRevision);
    });

    group('getArtifactPath', () {
      group('aot-tools', () {
        const aotToolsKernel = 'aot-tools.dill';
        const aotToolsExe = 'aot-tools';
        late String aotToolsKernelPath;
        late String aotToolsExePath;

        setUp(() {
          aotToolsKernelPath = p.join(
            artifactDirectory.path,
            engineRevision,
            aotToolsKernel,
          );
          aotToolsExePath = p.join(
            artifactDirectory.path,
            engineRevision,
            aotToolsExe,
          );
        });

        group('when kernel and executable are present', () {
          setUp(() {
            File(aotToolsKernelPath).createSync(recursive: true);
            File(aotToolsExePath).createSync(recursive: true);
          });

          test('returns path to kernel file', () async {
            expect(
              runWithOverrides(
                () => artifacts.getArtifactPath(
                  artifact: ShorebirdArtifact.aotTools,
                ),
              ),
              equals(aotToolsKernelPath),
            );
          });
        });

        group('when only executable is present', () {
          setUp(() {
            File(aotToolsExePath).createSync(recursive: true);
          });

          test('returns path to executable file', () {
            expect(
              runWithOverrides(
                () => artifacts.getArtifactPath(
                  artifact: ShorebirdArtifact.aotTools,
                ),
              ),
              equals(aotToolsExePath),
            );
          });
        });
      });

      test('returns the selected cached iOS engine binary', () {
        expect(
          runWithOverrides(
            () => artifacts.getArtifactPath(
              artifact: ShorebirdArtifact.iosEngineBinary,
            ),
          ),
          p.join(
            flutterDirectory.path,
            'bin',
            'cache',
            'artifacts',
            'engine',
            'ios-release',
            'Flutter.xcframework',
            'ios-arm64',
            'Flutter.framework',
            'Flutter',
          ),
        );
      });

      test('returns correct path for iOS gen_snapshot', () {
        expect(
          runWithOverrides(
            () => artifacts.getArtifactPath(
              artifact: ShorebirdArtifact.genSnapshotIos,
            ),
          ),
          equals(
            p.join(
              flutterDirectory.path,
              'bin',
              'cache',
              'artifacts',
              'engine',
              'ios-release',
              'gen_snapshot_arm64',
            ),
          ),
        );
      });

      test('returns correct path for macOS arm64 gen_snapshot', () {
        expect(
          runWithOverrides(
            () => artifacts.getArtifactPath(
              artifact: ShorebirdArtifact.genSnapshotMacosArm64,
            ),
          ),
          equals(
            p.join(
              flutterDirectory.path,
              'bin',
              'cache',
              'artifacts',
              'engine',
              'darwin-x64-release',
              'gen_snapshot_arm64',
            ),
          ),
        );
      });

      test('returns correct path for macOS x64 gen_snapshot', () {
        expect(
          runWithOverrides(
            () => artifacts.getArtifactPath(
              artifact: ShorebirdArtifact.genSnapshotMacosX64,
            ),
          ),
          equals(
            p.join(
              flutterDirectory.path,
              'bin',
              'cache',
              'artifacts',
              'engine',
              'darwin-x64-release',
              'gen_snapshot_x64',
            ),
          ),
        );
      });

      test('returns correct path for analyze_snapshot on iOS', () {
        expect(
          runWithOverrides(
            () => artifacts.getArtifactPath(
              artifact: ShorebirdArtifact.analyzeSnapshotIos,
            ),
          ),
          equals(
            p.join(
              flutterDirectory.path,
              'bin',
              'cache',
              'artifacts',
              'engine',
              'ios-release',
              'analyze_snapshot_arm64',
            ),
          ),
        );
      });

      test('returns correct paths for analyze_snapshot on macOS', () {
        expect(
          runWithOverrides(
            () => artifacts.getArtifactPath(
              artifact: ShorebirdArtifact.analyzeSnapshotMacosArm64,
            ),
          ),
          equals(
            p.join(
              artifactDirectory.path,
              engineRevision,
              'analyze-snapshot-macos-arm64',
            ),
          ),
        );
        expect(
          runWithOverrides(
            () => artifacts.getArtifactPath(
              artifact: ShorebirdArtifact.analyzeSnapshotMacosX64,
            ),
          ),
          equals(
            p.join(
              artifactDirectory.path,
              engineRevision,
              'analyze-snapshot-macos-x64',
            ),
          ),
        );
      });

      test('returns correct path for dartaotruntime', () {
        expect(
          runWithOverrides(
            () => artifacts.getArtifactPath(
              artifact: ShorebirdArtifact.dartAotRuntime,
            ),
          ),
          equals(
            p.join(
              flutterDirectory.path,
              'bin',
              'cache',
              'dart-sdk',
              'bin',
              'dartaotruntime',
            ),
          ),
        );
      });

      test('returns correct path for dart2bytecode snapshot', () {
        expect(
          runWithOverrides(
            () => artifacts.getArtifactPath(
              artifact: ShorebirdArtifact.dart2BytecodeSnapshot,
            ),
          ),
          equals(
            p.join(
              flutterDirectory.path,
              'bin',
              'cache',
              'dart-sdk',
              'bin',
              'snapshots',
              'dart2bytecode.dart.snapshot',
            ),
          ),
        );
      });

      test('returns correct path for Flutter product platform dill', () {
        expect(
          runWithOverrides(
            () => artifacts.getArtifactPath(
              artifact: ShorebirdArtifact.flutterProductPlatformDill,
            ),
          ),
          equals(
            p.join(
              flutterDirectory.path,
              'bin',
              'cache',
              'artifacts',
              'engine',
              'common',
              'flutter_patched_sdk_product',
              'platform_strong.dill',
            ),
          ),
        );
      });

      test('ignores unrelated workspace iOS platform dill', () {
        File(
          p.join(
            flutterDirectory.path,
            'engine',
            'src',
            'out',
            'ios_release',
            'flutter_patched_sdk',
            'platform_strong.dill',
          ),
        ).createSync(recursive: true);

        expect(
          runWithOverrides(
            () => artifacts.getArtifactPath(
              artifact: ShorebirdArtifact.flutterProductPlatformDill,
            ),
          ),
          equals(
            p.join(
              flutterDirectory.path,
              'bin',
              'cache',
              'artifacts',
              'engine',
              'common',
              'flutter_patched_sdk_product',
              'platform_strong.dill',
            ),
          ),
        );
      });
    });
  });

  group(ShorebirdLocalEngineArtifacts, () {
    late String localEngineSrcPath;
    late String localEngine;
    late String localEngineHost;
    late EngineConfig engineConfig;
    late ShorebirdLocalEngineArtifacts artifacts;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        () => body(),
        values: {engineConfigRef.overrideWith(() => engineConfig)},
      );
    }

    setUp(() {
      localEngineSrcPath = Directory.systemTemp
          .createTempSync('shorebird_local_artifacts_test_')
          .path;
      localEngine = 'local_engine';
      localEngineHost = 'local_engine_host';
      engineConfig = MockEngineConfig();
      artifacts = const ShorebirdLocalEngineArtifacts();

      when(
        () => engineConfig.localEngineSrcPath,
      ).thenReturn(localEngineSrcPath);
      when(() => engineConfig.localEngine).thenReturn(localEngine);
      when(() => engineConfig.localEngineHost).thenReturn(localEngineHost);
    });

    tearDown(() {
      Directory(localEngineSrcPath).deleteSync(recursive: true);
    });

    group('getArtifactPath', () {
      test('returns correct path for aot tools', () {
        expect(
          runWithOverrides(
            () =>
                artifacts.getArtifactPath(artifact: ShorebirdArtifact.aotTools),
          ),
          equals(
            p.join(
              localEngineSrcPath,
              'flutter',
              'third_party',
              'dart',
              'pkg',
              'aot_tools',
              'bin',
              'aot_tools.dart',
            ),
          ),
        );
      });

      test('returns correct path for gen_snapshot on iOS', () {
        final executable = File(
          p.join(
            localEngineSrcPath,
            'out',
            localEngine,
            'universal',
            'gen_snapshot_arm64',
          ),
        )..createSync(recursive: true);
        Process.runSync('chmod', ['+x', executable.path]);
        expect(
          runWithOverrides(
            () => artifacts.getArtifactPath(
              artifact: ShorebirdArtifact.genSnapshotIos,
            ),
          ),
          equals(
            p.join(
              localEngineSrcPath,
              'out',
              localEngine,
              'universal',
              'gen_snapshot_arm64',
            ),
          ),
        );
      });

      test('prefers the first runnable snapshot compiler candidate', () {
        final root = p.join(localEngineSrcPath, 'out', localEngine);
        for (final directory in ['.', 'universal', 'clang_x64']) {
          final executable = File(p.join(root, directory, 'gen_snapshot_arm64'))
            ..createSync(recursive: true);
          Process.runSync('chmod', ['+x', executable.path]);
        }
        expect(
          runWithOverrides(
            () => artifacts.getArtifactPath(
              artifact: ShorebirdArtifact.genSnapshotIos,
            ),
          ),
          p.join(root, 'gen_snapshot_arm64'),
        );
      });

      test('ignores nonexecutable snapshot compiler candidates', () {
        final root = p.join(localEngineSrcPath, 'out', localEngine);
        File(p.join(root, 'gen_snapshot_arm64')).createSync(recursive: true);
        final executable = File(
          p.join(root, 'clang_arm64', 'gen_snapshot_arm64'),
        )..createSync(recursive: true);
        Process.runSync('chmod', ['+x', executable.path]);
        expect(
          runWithOverrides(
            () => artifacts.getArtifactPath(
              artifact: ShorebirdArtifact.genSnapshotIos,
            ),
          ),
          executable.path,
        );
      });

      test('rejects a missing local iOS snapshot compiler', () {
        expect(
          () => runWithOverrides(
            () => artifacts.getArtifactPath(
              artifact: ShorebirdArtifact.genSnapshotIos,
            ),
          ),
          throwsStateError,
        );
      });

      test('selects physical iOS engine and excludes simulator slice', () {
        final xcframework = p.join(
          localEngineSrcPath,
          'out',
          localEngine,
          'Flutter.xcframework',
        );
        Directory(
          p.join(xcframework, 'ios-arm64-simulator'),
        ).createSync(recursive: true);
        Directory(p.join(xcframework, 'ios-arm64')).createSync(recursive: true);
        expect(
          runWithOverrides(
            () => artifacts.getArtifactPath(
              artifact: ShorebirdArtifact.iosEngineBinary,
            ),
          ),
          p.join(xcframework, 'ios-arm64', 'Flutter.framework', 'Flutter'),
        );
      });

      test('returns correct path for arm64 gen_snapshot on macOS', () {
        expect(
          runWithOverrides(
            () => artifacts.getArtifactPath(
              artifact: ShorebirdArtifact.genSnapshotMacosArm64,
            ),
          ),
          equals(
            p.join(
              localEngineSrcPath,
              'out',
              localEngine,
              'artifacts_arm64',
              'gen_snapshot',
            ),
          ),
        );
      });

      test('returns correct path for x64 gen_snapshot on macOS', () {
        expect(
          runWithOverrides(
            () => artifacts.getArtifactPath(
              artifact: ShorebirdArtifact.genSnapshotMacosX64,
            ),
          ),
          equals(
            p.join(
              localEngineSrcPath,
              'out',
              localEngine,
              'artifacts_x64',
              'gen_snapshot',
            ),
          ),
        );
      });

      test('returns correct path for analyze_snapshot on iOS', () {
        expect(
          runWithOverrides(
            () => artifacts.getArtifactPath(
              artifact: ShorebirdArtifact.analyzeSnapshotIos,
            ),
          ),
          equals(
            p.join(
              localEngineSrcPath,
              'out',
              localEngine,
              'clang_x64',
              'analyze_snapshot_arm64',
            ),
          ),
        );
      });

      test('returns correct paths for analyze_snapshot on macOS', () {
        expect(
          runWithOverrides(
            () => artifacts.getArtifactPath(
              artifact: ShorebirdArtifact.analyzeSnapshotMacosArm64,
            ),
          ),
          equals(
            p.join(
              localEngineSrcPath,
              'out',
              localEngine,
              'analyze_snapshot_arm64',
            ),
          ),
        );
        expect(
          runWithOverrides(
            () => artifacts.getArtifactPath(
              artifact: ShorebirdArtifact.analyzeSnapshotMacosX64,
            ),
          ),
          equals(
            p.join(
              localEngineSrcPath,
              'out',
              localEngine,
              'analyze_snapshot_x64',
            ),
          ),
        );
      });

      test('returns correct path for dartaotruntime', () {
        expect(
          runWithOverrides(
            () => artifacts.getArtifactPath(
              artifact: ShorebirdArtifact.dartAotRuntime,
            ),
          ),
          equals(
            p.join(
              localEngineSrcPath,
              'out',
              localEngineHost,
              'dartaotruntime',
            ),
          ),
        );
      });

      test('returns correct path for dart2bytecode snapshot', () {
        expect(
          runWithOverrides(
            () => artifacts.getArtifactPath(
              artifact: ShorebirdArtifact.dart2BytecodeSnapshot,
            ),
          ),
          equals(
            p.join(
              localEngineSrcPath,
              'out',
              localEngineHost,
              'dart-sdk',
              'bin',
              'snapshots',
              'dart2bytecode.dart.snapshot',
            ),
          ),
        );
      });

      test('returns correct path for Flutter product platform dill', () {
        expect(
          runWithOverrides(
            () => artifacts.getArtifactPath(
              artifact: ShorebirdArtifact.flutterProductPlatformDill,
            ),
          ),
          equals(
            p.join(
              localEngineSrcPath,
              'out',
              localEngine,
              'flutter_patched_sdk',
              'platform_strong.dill',
            ),
          ),
        );
      });
    });
  });
}
