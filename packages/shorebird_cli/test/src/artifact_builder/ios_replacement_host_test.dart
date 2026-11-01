import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_builder/ios_replacement_host.dart';
import 'package:shorebird_cli/src/engine_config.dart';
import 'package:shorebird_cli/src/shorebird_artifacts.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';
import 'package:test/test.dart';

import '../helpers.dart';
import '../mocks.dart';

void main() {
  useTempWorkingDirectory();

  group(IosReplacementHost, () {
    IosReplacementHost host({
      String version = 'version',
      String runtime = 'x',
    }) => IosReplacementHost(
      artifacts: {
        'engine': 'a' * 64,
        'gen_snapshot': 'b' * 64,
        'platform': 'c' * 64,
      },
      toolchainVersion: version,
      toolchainProvenance: {'dartaotruntime': runtime},
    );

    test('matches the independent u32 little endian SHA-256 fixture', () {
      expect(
        host().hostAbi,
        '26f4a45b3cdd50b49c8e5cc102d7ecd99e87777e6454d51662c9c793567bbcef',
      );
    });

    test(
      'macOS has an independent desktop ARM64 domain and release binding',
      () {
        final mac = IosReplacementHost(
          targetOS: 'macos',
          artifacts: host().artifacts,
          toolchainVersion: 'version',
          toolchainProvenance: {},
        );
        expect(
          mac.hostAbi,
          'c8ad62729c6baf7b76f9ae6ae0591ee2ba9b1fca858c9b84a14630d9210eaaaa',
        );
        expect(mac.hostAbi, isNot(host().hostAbi));
        mac.validateReleased(mac.manifest);
        for (final manifest in [
          host().manifest,
          {...mac.manifest, 'target_os': 'ios'},
          {...mac.manifest, 'target_arch': 'x64'},
        ]) {
          expect(
            () => mac.validateReleased(manifest),
            throwsA(isA<ArtifactBuildException>()),
          );
        }
      },
    );

    test(
      'macOS architecture selection is explicit and never shrinks universal',
      () {
        validateMacosFullReplacementBuildArgs([
          '--target-platform=darwin-arm64',
        ]);
        validateMacosFullReplacementBuildArgs([
          '--target-platform',
          'darwin-arm64',
        ]);
        for (final args in [
          <String>[],
          ['--target-platform=darwin-x64'],
          ['--target-platform=darwin-x64,darwin-arm64'],
          ['--target-platform=darwin-arm64', '--target-platform=darwin-arm64'],
          ['--target-platform=darwin-arm64', '--obfuscate'],
        ]) {
          expect(
            () => validateMacosFullReplacementBuildArgs(args),
            throwsA(isA<ArtifactBuildException>()),
          );
        }
      },
    );

    test('host runtime architecture does not change the ABI binding', () {
      final release = host(runtime: 'macos_arm64');
      final patch = host(runtime: 'macos_x64');
      expect(release.hostAbi, patch.hostAbi);
      patch.validateReleased(release.manifest);
    });

    test('validates the immutable release native artifacts and version', () {
      final current = host();
      current.validateReleased(current.manifest);
      for (final altered in [
        <String, Object?>{},
        {...current.manifest, 'host_abi_schema': 2},
        {...current.manifest, 'host_abi': 'd' * 64},
        {...current.manifest, 'host_artifacts': <String, String>{}},
        {
          ...current.manifest,
          'host_artifacts': {...current.artifacts, 'engine': 'd' * 64},
        },
        {...current.manifest, 'host_toolchain_version': 'other'},
      ]) {
        expect(
          () => current.validateReleased(altered),
          throwsA(isA<ArtifactBuildException>()),
        );
      }
    });
  });

  group(IosReplacementHostResolver, () {
    late ShorebirdArtifacts artifacts;
    late ShorebirdProcess process;
    late Map<ShorebirdArtifact, File> files;
    const resolver = IosReplacementHostResolver();
    const version = 'Dart SDK version: 3.14.0-edge.revision (main) (timestamp)';

    Future<IosReplacementHost> resolve({
      EngineConfig? engineConfig,
      String targetOS = 'ios',
    }) => runScoped(
      () => resolver.resolve(targetOS: targetOS),
      values: {
        shorebirdArtifactsRef.overrideWith(() => artifacts),
        processRef.overrideWith(() => process),
        engineConfigRef.overrideWith(
          () => engineConfig ?? const EngineConfig.empty(),
        ),
      },
    );

    void setVersion(ShorebirdArtifact artifact, String output) {
      when(
        () => process.run(
          files[artifact]!.path,
          ['--version'],
          useVendedFlutter: false,
        ),
      ).thenAnswer(
        (_) async => ShorebirdProcessResult(
          exitCode: 0,
          stdout: '',
          stderr: output,
        ),
      );
    }

    setUp(() {
      final engine = Directory('engine');
      if (engine.existsSync()) engine.deleteSync(recursive: true);
      artifacts = MockShorebirdArtifacts();
      process = MockShorebirdProcess();
      files = {
        for (final artifact in [
          ShorebirdArtifact.iosEngineBinary,
          ShorebirdArtifact.macosEngineBinary,
          ShorebirdArtifact.genSnapshotMacosFullReplacementArm64,
          ShorebirdArtifact.genSnapshotIos,
          ShorebirdArtifact.flutterProductPlatformDill,
          ShorebirdArtifact.dartAotRuntime,
          ShorebirdArtifact.dart2BytecodeSnapshot,
        ])
          artifact: File(artifact.name)..writeAsStringSync(artifact.name),
      };
      for (final entry in files.entries) {
        when(
          () => artifacts.getArtifactPath(artifact: entry.key),
        ).thenReturn(entry.value.path);
      }
      setVersion(ShorebirdArtifact.genSnapshotIos, '$version on "macos_arm64"');
      setVersion(
        ShorebirdArtifact.genSnapshotMacosFullReplacementArm64,
        '$version on "macos_arm64"',
      );
      setVersion(ShorebirdArtifact.dartAotRuntime, '$version on "macos_x64"');
      when(
        () => process.run(
          files[ShorebirdArtifact.dartAotRuntime]!.path,
          [files[ShorebirdArtifact.dart2BytecodeSnapshot]!.path, '--help'],
          useVendedFlutter: false,
        ),
      ).thenAnswer(
        (_) async => const ShorebirdProcessResult(
          exitCode: 0,
          stdout:
              '--[no-]shorebird-full-replacement --shorebird-host-abi '
              '--source additional.dart',
          stderr: '',
        ),
      );
    });

    test(
      'hashes the actual selected artifacts and proves compiler loading',
      () async {
        final host = await resolve();
        expect(host.toolchainVersion, version);
        expect(
          host.artifacts['engine'],
          sha256.convert(utf8.encode('iosEngineBinary')).toString(),
        );
        expect(host.artifacts.keys, ['engine', 'gen_snapshot', 'platform']);
        expect(host.toolchainProvenance.keys, [
          'dartaotruntime',
          'dart2bytecode',
        ]);
        verify(
          () => process.run(
            files[ShorebirdArtifact.dartAotRuntime]!.path,
            [files[ShorebirdArtifact.dart2BytecodeSnapshot]!.path, '--help'],
            useVendedFlutter: false,
          ),
        ).called(1);
      },
    );

    test('rejects mixed cached SDK versions', () async {
      setVersion(
        ShorebirdArtifact.genSnapshotIos,
        'Dart SDK version: 3.12.0 (other) on "macos_arm64"',
      );
      await expectLater(resolve(), throwsA(isA<ArtifactBuildException>()));
    });

    test(
      'does not discard revision or timestamp version differences',
      () async {
        setVersion(
          ShorebirdArtifact.genSnapshotIos,
          '$version different-timestamp on "macos_arm64"',
        );
        await expectLater(resolve(), throwsA(isA<ArtifactBuildException>()));
      },
    );

    test('rejects an incompatible compiler snapshot', () async {
      when(
        () => process.run(
          files[ShorebirdArtifact.dartAotRuntime]!.path,
          [files[ShorebirdArtifact.dart2BytecodeSnapshot]!.path, '--help'],
          useVendedFlutter: false,
        ),
      ).thenAnswer(
        (_) async => const ShorebirdProcessResult(
          exitCode: 255,
          stdout: '',
          stderr: 'Wrong snapshot version',
        ),
      );
      await expectLater(resolve(), throwsA(isA<ArtifactBuildException>()));
    });

    test(
      'rejects stale compiler snapshots missing required capabilities',
      () async {
        when(
          () => process.run(
            files[ShorebirdArtifact.dartAotRuntime]!.path,
            [files[ShorebirdArtifact.dart2BytecodeSnapshot]!.path, '--help'],
            useVendedFlutter: false,
          ),
        ).thenAnswer(
          (_) async => const ShorebirdProcessResult(
            exitCode: 0,
            stdout: 'usage --source-positions',
            stderr: '',
          ),
        );
        await expectLater(resolve(), throwsA(isA<ArtifactBuildException>()));
      },
    );

    test('rejects missing and empty artifacts before starting tools', () async {
      files[ShorebirdArtifact.iosEngineBinary]!.deleteSync();
      await expectLater(resolve(), throwsA(isA<ArtifactBuildException>()));
      files[ShorebirdArtifact.iosEngineBinary]!.writeAsStringSync('');
      await expectLater(resolve(), throwsA(isA<ArtifactBuildException>()));
      verifyZeroInteractions(process);
    });

    const local = EngineConfig(
      localEngineSrcPath: 'engine',
      localEngine: 'release',
      localEngineHost: 'host_release',
    );
    const productArgs = '''
is_debug = false
flutter_runtime_mode = "release"
dart_runtime_mode = "release"
target_os = "ios"
target_cpu = "arm64"
dart_target_arch = "arm64"
use_ios_simulator = false
ios_use_simulator = false
''';
    void writeArgs(String contents) {
      File(p.join('engine', 'out', 'release', 'args.gn'))
        ..createSync(recursive: true)
        ..writeAsStringSync(contents);
    }

    test('accepts a verified local product SDK directory', () async {
      writeArgs(productArgs);
      expect((await resolve(engineConfig: local)).toolchainVersion, version);
    });

    test(
      'macOS rejects hosted and mismatched local engines before tools',
      () async {
        await expectLater(
          resolve(targetOS: 'macos'),
          throwsA(isA<ArtifactBuildException>()),
        );
        final macProductArgs = productArgs.replaceFirst(
          'target_os = "ios"',
          'target_os = "mac"',
        );
        final macArgs =
            '$macProductArgs'
            '\ndart_enable_shorebird_interpreter = true\n'
            'shorebird_use_interpreter = false\n';
        for (final args in [
          productArgs,
          macArgs.replaceFirst('is_debug = false', 'is_debug = true'),
          macArgs.replaceFirst('target_cpu = "arm64"', 'target_cpu = "x64"'),
          macArgs.replaceFirst(
            'dart_target_arch = "arm64"',
            'dart_target_arch = "x64"',
          ),
          macArgs.replaceFirst(
            'dart_enable_shorebird_interpreter = true',
            'dart_enable_shorebird_interpreter = false',
          ),
          macArgs.replaceFirst(
            'shorebird_use_interpreter = false',
            'shorebird_use_interpreter = true',
          ),
          '$macArgs\ntarget_cpu = another_cpu\n',
          macArgs.replaceFirst('dart_enable_shorebird_interpreter = true', ''),
        ]) {
          writeArgs(args);
          await expectLater(
            resolve(targetOS: 'macos', engineConfig: local),
            throwsA(isA<ArtifactBuildException>()),
          );
        }
        verifyZeroInteractions(process);
        writeArgs(macArgs);
        final mac = await resolve(targetOS: 'macos', engineConfig: local);
        expect(mac.targetOS, 'macos');
        expect(
          mac.artifacts['engine'],
          sha256.convert(utf8.encode('macosEngineBinary')).toString(),
        );
      },
    );

    test(
      'rejects absent, debug, simulator and non-arm64 local metadata',
      () async {
        await expectLater(
          resolve(engineConfig: local),
          throwsA(isA<ArtifactBuildException>()),
        );
        for (final args in [
          productArgs.replaceFirst('is_debug = false', 'is_debug = true'),
          '$productArgs\nuse_ios_simulator = true\n',
          '$productArgs\ntarget_cpu = "x64"\n',
          productArgs.replaceFirst('dart_runtime_mode = "release"', ''),
        ]) {
          writeArgs(args);
          await expectLater(
            resolve(engineConfig: local),
            throwsA(isA<ArtifactBuildException>()),
          );
        }
        verifyZeroInteractions(process);
      },
    );
  });
}
