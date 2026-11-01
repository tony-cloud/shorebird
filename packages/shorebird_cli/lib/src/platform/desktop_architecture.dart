import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/abi.dart';
import 'package:shorebird_cli/src/platform/platform.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';

/// Architecture routing for native Linux and Windows builds.
/// Host tool architecture and application architecture are separate: desktop
/// builds currently require both to match, and never support cross compilation.
class DesktopArchitecture {
  /// The architecture of the native Dart process for [operatingSystem].
  static Arch native(String operatingSystem) {
    final current = abi.current;
    return switch (current) {
      Abi.linuxArm64 || Abi.windowsArm64 || Abi.macosArm64 => Arch.arm64,
      Abi.linuxX64 || Abi.windowsX64 || Abi.macosX64 => Arch.x86_64,
      _ => throw UnsupportedError(
        'Native $operatingSystem builds require an x64 or ARM64 Dart SDK; '
        'found $current.',
      ),
    };
  }

  /// Flutter's spelling of the architecture used in build directories.
  static String directory(Arch arch) => switch (arch) {
    Arch.arm64 => 'arm64',
    Arch.x86_64 => 'x64',
    _ => throw UnsupportedError('Unsupported desktop architecture: $arch'),
  };

  /// Keeps historical x64 archive keys while isolating ARM64 archives.
  static String artifact(String legacyKey, Arch arch) =>
      arch == Arch.arm64 ? '${legacyKey}_aarch64' : legacyKey;

  /// Rejects cross builds, including target flags forwarded after `--`.
  static void validateBuildArgs(String operatingSystem, List<String> args) {
    final expected = '$operatingSystem-${directory(native(operatingSystem))}';
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      String? value;
      if (arg.startsWith('--target-platform=')) {
        value = arg.substring('--target-platform='.length);
      } else if (arg == '--target-platform') {
        if (++i == args.length) {
          throw const FormatException('Missing --target-platform value.');
        }
        value = args[i];
      }
      if (value != null && operatingSystem == 'windows' && value == expected) {
        throw UnsupportedError(
          'Windows selects its target from the native Dart SDK. '
          'Omit --target-platform.',
        );
      }
      if (value != null && value != expected) {
        throw UnsupportedError(
          'Desktop cross compilation is unsupported. Expected $expected; '
          'received $value. Run Shorebird with a native Dart SDK.',
        );
      }
    }
  }

  /// Ensures Flutter will actually run a native ARM64 Dart SDK, rather than
  /// silently using an x64 SDK downloaded by an older bootstrap script.
  static void validateFlutterSdk(String operatingSystem) {
    final arch = native(operatingSystem);
    if (arch != Arch.arm64) return;
    final dart = File(
      p.join(
        shorebirdEnv.flutterDirectory.path,
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        operatingSystem == 'windows' ? 'dart.exe' : 'dart',
      ),
    );
    validateBinary(
      dart,
      arch,
      portableExecutable: operatingSystem == 'windows',
    );
  }

  /// Checks ELF or PE machine metadata before a binary is uploaded or diffed.
  static void validateBinary(
    File file,
    Arch expected, {
    bool portableExecutable = false,
  }) {
    final bytes = file.readAsBytesSync();
    final data = ByteData.sublistView(bytes);
    int? machine;
    if (portableExecutable) {
      if (bytes.length >= 64 && bytes[0] == 0x4d && bytes[1] == 0x5a) {
        final offset = data.getUint32(0x3c, Endian.little);
        if (offset <= bytes.length - 6 &&
            data.getUint32(offset, Endian.little) == 0x4550) {
          machine = data.getUint16(offset + 4, Endian.little);
        }
      }
    } else if (bytes.length >= 20 &&
        bytes[0] == 0x7f &&
        bytes[1] == 0x45 &&
        bytes[2] == 0x4c &&
        bytes[3] == 0x46 &&
        bytes[4] == 2 &&
        bytes[5] == 1) {
      machine = data.getUint16(18, Endian.little);
    }
    final expectedMachine = portableExecutable
        ? (expected == Arch.arm64 ? 0xaa64 : 0x8664)
        : (expected == Arch.arm64 ? 183 : 62);
    if (machine != expectedMachine) {
      throw FormatException(
        'Expected ${expected.arch} ${portableExecutable ? 'PE' : 'ELF'} '
        'binary at ${file.path}; found machine $machine.',
      );
    }
  }
}
