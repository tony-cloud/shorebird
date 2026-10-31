import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/engine_config.dart';
import 'package:shorebird_cli/src/shorebird_artifacts.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';

/// The resolver used by full-replacement releases and patches.
final iosReplacementHostResolverRef = create(IosReplacementHostResolver.new);

/// The current full-replacement host resolver.
IosReplacementHostResolver get iosReplacementHostResolver =>
    read(iosReplacementHostResolverRef);

/// A fingerprint of the actual native iOS host, independent of cache paths.
class IosReplacementHost {
  /// Creates a host from the selected artifacts' SHA-256 fingerprints.
  IosReplacementHost({
    required Map<String, String> artifacts,
    required this.toolchainVersion,
    required Map<String, String> toolchainProvenance,
  }) : artifacts = Map.unmodifiable(artifacts),
       toolchainProvenance = Map.unmodifiable(toolchainProvenance);

  /// Native host inputs in the canonical descriptor.
  final Map<String, String> artifacts;

  /// Version reported by both the snapshot compiler and bytecode runtime.
  final String toolchainVersion;

  /// Compiler and host runtime fingerprints, recorded outside the native ABI.
  final Map<String, String> toolchainProvenance;

  /// SHA-256 of UTF-8 fields, each prefixed by its unsigned u32 LE byte length.
  String get hostAbi {
    final descriptor = BytesBuilder(copy: false);
    for (final value in [
      'shorebird-ios-full-replacement-host-v1',
      'ios',
      'device',
      'arm64',
      'product',
      'dart-bytecode-interpreter',
      'full-replacement-v1',
      artifacts['engine']!,
      artifacts['gen_snapshot']!,
      artifacts['platform']!,
    ]) {
      final encoded = utf8.encode(value);
      final length = ByteData(4)..setUint32(0, encoded.length, Endian.little);
      descriptor
        ..add(length.buffer.asUint8List())
        ..add(encoded);
    }
    return sha256.convert(descriptor.takeBytes()).toString();
  }

  /// Immutable release supplement fields used to validate future patch tools.
  Map<String, Object?> get manifest => {
    'host_abi_schema': 1,
    'host_abi': hostAbi,
    'host_artifacts': artifacts,
    'host_toolchain_version': toolchainVersion,
    'host_toolchain_provenance': toolchainProvenance,
  };

  /// Refuses a patch built against a different frozen native host.
  void validateReleased(Map<String, Object?> manifest) {
    final releasedArtifacts = manifest['host_artifacts'];
    if (manifest['host_abi_schema'] != 1 ||
        manifest['host_abi'] != hostAbi ||
        releasedArtifacts is! Map ||
        releasedArtifacts.length != artifacts.length ||
        artifacts.entries.any(
          (entry) => releasedArtifacts[entry.key] != entry.value,
        ) ||
        manifest['host_toolchain_version'] != toolchainVersion) {
      throw ArtifactBuildException(
        'The selected iOS toolchain does not match the released '
        'full-replacement host. Use the exact released engine, snapshot '
        'compiler and platform SDK, '
        'or create a new native release.',
      );
    }
  }
}

/// Resolves the same release/device/arm64 artifacts as Flutter's native build.
class IosReplacementHostResolver {
  /// Creates a resolver for the currently selected engine configuration.
  const IosReplacementHostResolver();

  /// Validates the product toolchain and hashes its actual selected binaries.
  Future<IosReplacementHost> resolve() async {
    _validateLocalProductConfiguration();
    final files = <String, File>{
      'engine': _artifact(ShorebirdArtifact.iosEngineBinary),
      'gen_snapshot': _artifact(ShorebirdArtifact.genSnapshotIos),
      'platform': _artifact(ShorebirdArtifact.flutterProductPlatformDill),
      'dartaotruntime': _artifact(ShorebirdArtifact.dartAotRuntime),
      'dart2bytecode': _artifact(ShorebirdArtifact.dart2BytecodeSnapshot),
    };
    for (final entry in files.entries) {
      if (!entry.value.existsSync() || entry.value.lengthSync() == 0) {
        throw ArtifactBuildException(
          'Missing full-replacement ${entry.key} artifact: '
          '${entry.value.path}. '
          'Build or download a complete matching release toolchain first.',
        );
      }
    }
    final snapshotVersion = await _version(files['gen_snapshot']!);
    final runtimeVersion = await _version(files['dartaotruntime']!);
    if (snapshotVersion != runtimeVersion) {
      throw ArtifactBuildException(
        'Mixed Dart toolchains cannot build a full-replacement host: '
        'gen_snapshot reports "$snapshotVersion", while dartaotruntime reports '
        '"$runtimeVersion". Rebuild or download matching artifacts.',
      );
    }
    // Loading the compiler snapshot catches incompatible cached snapshots even
    // when the two native executables report the same SDK version.
    final compiler = await process.run(
      files['dartaotruntime']!.path,
      [files['dart2bytecode']!.path, '--help'],
      useVendedFlutter: false,
    );
    if (compiler.exitCode != 0) {
      throw ArtifactBuildException(
        'The selected dart2bytecode snapshot cannot run with the selected '
        'dartaotruntime. Rebuild or download matching artifacts. '
        '${compiler.stderr}',
      );
    }
    final compilerHelp = '${compiler.stdout}\n${compiler.stderr}';
    if (!compilerHelp.contains('shorebird-full-replacement') ||
        !compilerHelp.contains('--shorebird-host-abi') ||
        !RegExp(r'--source(?:[=\s]|$)').hasMatch(compilerHelp)) {
      throw ArtifactBuildException(
        'The selected dart2bytecode snapshot does not support full '
        'replacement, '
        'host ABI binding and additional source roots. Rebuild or download '
        'the matching full-replacement compiler snapshot.',
      );
    }
    final fingerprints = <String, String>{};
    for (final entry in files.entries) {
      fingerprints[entry.key] =
          (await sha256.bind(entry.value.openRead()).first).toString();
    }
    return IosReplacementHost(
      artifacts: {
        for (final key in ['engine', 'gen_snapshot', 'platform'])
          key: fingerprints[key]!,
      },
      toolchainVersion: snapshotVersion,
      toolchainProvenance: {
        for (final key in ['dartaotruntime', 'dart2bytecode'])
          key: fingerprints[key]!,
      },
    );
  }

  File _artifact(ShorebirdArtifact artifact) =>
      File(shorebirdArtifacts.getArtifactPath(artifact: artifact));

  Future<String> _version(File executable) async {
    final result = await process.run(
      executable.path,
      ['--version'],
      useVendedFlutter: false,
    );
    final output = '${result.stdout}\n${result.stderr}'.trim();
    // Only the host architecture suffix may differ. SDK revision, build mode,
    // channel and timestamp remain part of the compatibility comparison.
    final normalized = output.replaceFirst(RegExp(r' on "[^"]+"$'), '');
    if (result.exitCode != 0 ||
        !RegExp(r'^Dart SDK version: [^\r\n]+$').hasMatch(normalized)) {
      throw ArtifactBuildException(
        'Unable to identify the selected Dart tool ${executable.path}: $output',
      );
    }
    return normalized;
  }

  void _validateLocalProductConfiguration() {
    if (engineConfig.localEngine == null) return;
    final arguments = File(
      p.join(
        engineConfig.localEngineSrcPath!,
        'out',
        engineConfig.localEngine,
        'args.gn',
      ),
    );
    if (!arguments.existsSync()) {
      throw ArtifactBuildException(
        'Full replacement requires local engine args.gn to verify the '
        'release/device/arm64 product SDK: ${arguments.path}.',
      );
    }
    final values = <String, String>{};
    for (final line in const LineSplitter().convert(
      arguments.readAsStringSync(),
    )) {
      final assignment = RegExp(
        r'^\s*([a-zA-Z_][a-zA-Z_0-9]*)\s*=\s*("[^"]*"|true|false)\s*(?:#.*)?$',
      ).firstMatch(line);
      if (assignment != null) {
        values[assignment[1]!] = assignment[2]!.replaceAll('"', '');
      }
    }
    const required = {
      'target_os': 'ios',
      'target_cpu': 'arm64',
      'is_debug': 'false',
      'flutter_runtime_mode': 'release',
      'dart_runtime_mode': 'release',
      'dart_target_arch': 'arm64',
      'use_ios_simulator': 'false',
      'ios_use_simulator': 'false',
    };
    if (required.entries.any((entry) => values[entry.key] != entry.value)) {
      throw ArtifactBuildException(
        'Full replacement requires an iOS arm64 device release engine. '
        'The selected args.gn does not establish this product profile: '
        '${arguments.path}.',
      );
    }
  }
}
