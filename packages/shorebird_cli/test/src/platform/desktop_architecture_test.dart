import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:platform/testing.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/abi.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/cache.dart';
import 'package:shorebird_cli/src/commands/patch/linux_patcher.dart';
import 'package:shorebird_cli/src/commands/patch/windows_patcher.dart';
import 'package:shorebird_cli/src/commands/release/linux_releaser.dart';
import 'package:shorebird_cli/src/commands/release/windows_releaser.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform/desktop_architecture.dart';
import 'package:shorebird_cli/src/platform/platform.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:test/test.dart';

import '../helpers.dart';
import '../mocks.dart';

List<int> peHeader({required bool arm64}) {
  final bytes = Uint8List(72)..setAll(0, [0x4d, 0x5a]);
  ByteData.sublistView(bytes)
    ..setUint32(0x3c, 64, Endian.little)
    ..setUint32(64, 0x4550, Endian.little)
    ..setUint16(68, arm64 ? 0xaa64 : 0x8664, Endian.little);
  return bytes;
}

void main() {
  useTempWorkingDirectory();

  R withAbi<R>(Abi value, R Function() body) => runScoped(
    body,
    values: {abiRef.overrideWith(() => TestDesktopAbi(value))},
  );

  for (final os in ['linux', 'windows']) {
    final arm64 = os == 'linux' ? Abi.linuxArm64 : Abi.windowsArm64;
    final x64 = os == 'linux' ? Abi.linuxX64 : Abi.windowsX64;
    group(os, () {
      test('selects the native process architecture', () {
        expect(
          withAbi(arm64, () => DesktopArchitecture.native(os)),
          Arch.arm64,
        );
        expect(withAbi(x64, () => DesktopArchitecture.native(os)), Arch.x86_64);
      });

      test('rejects unsupported native ABIs', () {
        expect(
          () => withAbi(Abi.linuxArm, () => DesktopArchitecture.native(os)),
          throwsUnsupportedError,
        );
      });

      test('accepts a matching target and rejects all cross-target forms', () {
        withAbi(arm64, () {
          DesktopArchitecture.validateBuildArgs(os, []);
          if (os == 'linux') {
            DesktopArchitecture.validateBuildArgs(os, [
              '--target-platform=$os-arm64',
            ]);
          } else {
            expect(
              () => DesktopArchitecture.validateBuildArgs(os, [
                '--target-platform=$os-arm64',
              ]),
              throwsUnsupportedError,
            );
          }
          for (final args in [
            ['--target-platform=$os-x64'],
            ['--target-platform', '$os-x64'],
            ['--target-platform=$os-arm64', '--target-platform=$os-x64'],
            ['--target-platform=$os-arm64,$os-x64'],
            ['--target-platform=android-arm64'],
          ]) {
            expect(
              () => DesktopArchitecture.validateBuildArgs(os, args),
              throwsUnsupportedError,
            );
          }
          expect(
            () => DesktopArchitecture.validateBuildArgs(os, [
              '--target-platform',
            ]),
            throwsFormatException,
          );
        });
      });

      test(
        'isolates the native patch cache and rejects cached x64 tools',
        () async {
          final cache = MockCache();
          final directory = Directory.systemTemp.createTempSync();
          addTearDown(() => directory.deleteSync(recursive: true));
          when(() => cache.getArtifactDirectory(any())).thenReturn(directory);
          final tool = PatchArtifact(
            cache: cache,
            platform: TestNativePlatform(operatingSystem: os),
          );
          await withAbi(
            arm64,
            () => runScoped(() async {
              expect(
                tool.file.path,
                p.join(
                  directory.path,
                  '$os-arm64',
                  os == 'windows' ? 'patch.exe' : 'patch',
                ),
              );
              tool.file.createSync(recursive: true);
              tool.stampFile.createSync();
              tool.file.writeAsBytesSync(
                os == 'windows' ? peHeader(arm64: false) : desktopElfHeader(),
              );
              expect(await tool.isValid(), isFalse);
              tool.file.writeAsBytesSync(
                os == 'windows'
                    ? peHeader(arm64: true)
                    : desktopElfHeader(arm64: true),
              );
              expect(await tool.isValid(), isTrue);
            }, values: {loggerRef.overrideWith(MockShorebirdLogger.new)}),
          );
          withAbi(
            x64,
            () => expect(
              tool.file.path,
              p.join(directory.path, os == 'windows' ? 'patch.exe' : 'patch'),
            ),
          );
        },
      );

      test('requires a native ARM64 Flutter Dart executable', () {
        final env = MockShorebirdEnv();
        final flutter = Directory.systemTemp.createTempSync();
        addTearDown(() => flutter.deleteSync(recursive: true));
        when(() => env.flutterDirectory).thenReturn(flutter);
        final dart = File(
          p.join(
            flutter.path,
            'bin',
            'cache',
            'dart-sdk',
            'bin',
            os == 'windows' ? 'dart.exe' : 'dart',
          ),
        )..createSync(recursive: true);
        List<int> header({required bool arm64}) => os == 'windows'
            ? peHeader(arm64: arm64)
            : desktopElfHeader(arm64: arm64);
        withAbi(
          arm64,
          () => runScoped(() {
            dart.writeAsBytesSync(header(arm64: false));
            expect(
              () => DesktopArchitecture.validateFlutterSdk(os),
              throwsFormatException,
            );
            dart.writeAsBytesSync(header(arm64: true));
            expect(
              () => DesktopArchitecture.validateFlutterSdk(os),
              returnsNormally,
            );
            dart.writeAsBytesSync([0x4d, 0x5a]);
            expect(
              () => DesktopArchitecture.validateFlutterSdk(os),
              throwsFormatException,
            );
          }, values: {shorebirdEnvRef.overrideWith(() => env)}),
        );
      });

      test(
        'routes bundle paths, release keys, and supplements consistently',
        () {
          final env = MockShorebirdEnv();
          final project = Directory.systemTemp.createTempSync();
          addTearDown(() => project.deleteSync(recursive: true));
          when(env.getShorebirdProjectRoot).thenReturn(project);
          withAbi(
            arm64,
            () => runScoped(() {
              final manager = ArtifactManager();
              final parser = MockArgParser();
              final args = MockArgResults();
              if (os == 'linux') {
                final patcher = LinuxPatcher(
                  argParser: parser,
                  argResults: args,
                  flavor: null,
                  target: null,
                );
                final releaser = LinuxReleaser(
                  argResults: args,
                  flavor: null,
                  target: null,
                );
                expect(
                  manager.linuxBundleDirectory.path,
                  p.join(
                    project.path,
                    'build',
                    'linux',
                    'arm64',
                    'release',
                    'bundle',
                  ),
                );
                expect(patcher.primaryReleaseArtifactArch, 'bundle_aarch64');
                expect(
                  patcher.supplementaryReleaseArtifactArch,
                  'linux_supplement_aarch64',
                );
                expect(
                  releaser.supplementArtifactArch,
                  patcher.supplementaryReleaseArtifactArch,
                );
              } else {
                final patcher = WindowsPatcher(
                  argParser: parser,
                  argResults: args,
                  flavor: null,
                  target: null,
                );
                final releaser = WindowsReleaser(
                  argResults: args,
                  flavor: null,
                  target: null,
                );
                expect(
                  manager.getWindowsReleaseDirectory().path,
                  p.join(
                    project.path,
                    'build',
                    'windows',
                    'arm64',
                    'runner',
                    'Release',
                  ),
                );
                expect(
                  patcher.primaryReleaseArtifactArch,
                  'win_archive_aarch64',
                );
                expect(
                  patcher.supplementaryReleaseArtifactArch,
                  'windows_supplement_aarch64',
                );
                expect(
                  releaser.supplementArtifactArch,
                  patcher.supplementaryReleaseArtifactArch,
                );
              }
            }, values: {shorebirdEnvRef.overrideWith(() => env)}),
          );
        },
      );
    });
  }

  test('rejects incorrect, truncated, and unsupported ELF machine types', () {
    final file = File(p.join(Directory.current.path, 'app.so'));
    for (final bytes in <List<int>>[
      [],
      [0x7f],
      desktopElfHeader(),
      desktopElfHeader()..[18] = 3,
    ]) {
      file.writeAsBytesSync(bytes);
      expect(
        () => DesktopArchitecture.validateBinary(file, Arch.arm64),
        throwsFormatException,
      );
    }
    file.writeAsBytesSync(desktopElfHeader(arm64: true));
    expect(
      () => DesktopArchitecture.validateBinary(file, Arch.arm64),
      returnsNormally,
    );
  });
}
