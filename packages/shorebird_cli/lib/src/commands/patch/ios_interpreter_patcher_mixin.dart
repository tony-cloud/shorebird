import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:mason_logger/mason_logger.dart';
import 'package:open_aot_patch_tools/open_aot_patch_tools.dart' as open_patch;
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_builder/ios_bytecode_builder.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/commands/patch/patcher.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/extensions/directory.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/platform/platform.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';

/// Builds and packages public, data-only iOS interpreter patches.
mixin IosInterpreterPatcherMixin on Patcher {
  /// Podfile.lock hash when patching an application rather than a framework.
  String? get interpreterPodfileLockHash => null;

  String get _interpreterPatchOutputPath =>
      p.join(shorebirdEnv.buildDirectory.path, 'ios_interpreter_patch.vmcode');

  String get _interpreterPatchBytecodeOutputPath => p.join(
    shorebirdEnv.buildDirectory.path,
    'ios_interpreter_patch.bytecode',
  );

  /// Runtime mode selected for this iOS patch.
  String get iosPatchRuntimeMode {
    final environmentMode =
        platform.environment['SHOREBIRD_IOS_PATCH_RUNTIME_MODE'];
    if (environmentMode != null && environmentMode.trim().isNotEmpty) {
      return environmentMode.trim();
    }
    if (allowsNativeIosAotPatch) {
      return open_patch.runtimeModeNativeAot;
    }
    return shorebirdEnv.getShorebirdYaml()?.aotPatchRuntimeMode ??
        open_patch.runtimeModeDartBytecodeInterpreter;
  }

  /// Whether native executable patches were explicitly enabled for development.
  bool get allowsNativeIosAotPatch {
    final value = platform.environment['SHOREBIRD_IOS_NATIVE_AOT_PATCH'];
    return value == '1' || value == 'true' || value == 'yes';
  }

  @override
  void preflightReleaseArtifact(File releaseArchive) {
    if (iosPatchRuntimeMode != open_patch.runtimeModeDartBytecodeInterpreter) {
      return;
    }
    final manifest = _baselineManifest(_baselineBytecode());
    IosBytecodeBuilder.validateCompiledPolicy(releaseArchive, manifest);
  }

  /// Packages encrypted bytecode in the public updater transport format.
  Future<Map<Arch, PatchArtifactBundle>> createInterpreterPatchArtifacts({
    required String appId,
    required String? releaseVersion,
    required int releaseId,
    required File releaseArtifact,
  }) async {
    final shorebirdYaml = shorebirdEnv.getShorebirdYaml();
    if (shorebirdYaml == null) {
      logger.err('Unable to find shorebird.yaml for iOS interpreter patch.');
      throw ProcessExit(ExitCode.software.code);
    }

    if (obfuscate) {
      logger.err(
        'Obfuscated releases cannot receive iOS interpreter body patches. '
        'Create an interpreter release without --obfuscate.',
      );
      throw ProcessExit(ExitCode.usage.code);
    }
    final baseline = _baselineBytecode();
    final baselineHash = open_patch.sha256Hex(baseline.readAsBytesSync());
    final manifest = _baselineManifest(baseline);
    IosBytecodeBuilder.validateCompiledPolicy(releaseArtifact, manifest);
    final expected = <String, Object?>{
      'app_id': appId,
      'release_id': releaseId,
      'app_build_id': releaseVersion,
      'base_snapshot_hash': baselineHash,
    };
    for (final entry in expected.entries) {
      if (entry.value != null && manifest[entry.key] != entry.value) {
        logger.err(
          'Interpreter baseline supplement does not match ${entry.key}.',
        );
        throw ProcessExit(ExitCode.usage.code);
      }
    }

    final bytecodePath = _configuredInterpreterBytecodePath(shorebirdYaml);
    final bytecodeFile = bytecodePath == null
        ? File(_interpreterPatchBytecodeOutputPath)
        : _projectRelativeFile(bytecodePath);
    if (!bytecodeFile.existsSync()) {
      logger.err(
        bytecodePath == null
            ? '''
Unable to find generated iOS interpreter patch bytecode: ${bytecodeFile.path}
Run `shorebird patch ios` so the patch build can generate it, or set aot_patch_bytecode_path/SHOREBIRD_IOS_INTERPRETER_PATCH_PATH to a Dart bytecode payload.'''
            : '''
iOS interpreter patch bytecode does not exist: ${bytecodeFile.path}''',
      );
      throw ProcessExit(ExitCode.software.code);
    }
    final patchSnapshot = bytecodeFile.readAsBytesSync();
    if (_looksLikeNativeExecutable(patchSnapshot)) {
      logger.err(
        '''
iOS interpreter patch payload must be Dart bytecode data, not a native Mach-O or ELF artifact: ${bytecodeFile.path}''',
      );
      throw ProcessExit(ExitCode.software.code);
    }

    final keyId = _requiredPatchValue(
      'aot_patch_key_id or SHOREBIRD_AOT_PATCH_KEY_ID',
      platform.environment['SHOREBIRD_AOT_PATCH_KEY_ID'] ??
          shorebirdYaml.aotPatchKeyId ??
          manifest['key_id'] as String?,
    );
    final keyHex = _requiredPatchValue(
      'SHOREBIRD_AOT_PATCH_KEY_HEX',
      platform.environment['SHOREBIRD_AOT_PATCH_KEY_HEX'] ??
          shorebirdYaml.aotPatchKeyHex,
    );
    final appBuildId = _requiredPatchValue(
      'release version or aot_patch_app_build_id',
      releaseVersion ??
          platform.environment['SHOREBIRD_AOT_PATCH_APP_BUILD_ID'] ??
          shorebirdYaml.aotPatchAppBuildId,
    );
    final flavorId = _requiredPatchValue(
      'aot_patch_flavor_id',
      platform.environment['SHOREBIRD_AOT_PATCH_FLAVOR_ID'] ??
          shorebirdYaml.aotPatchFlavorId,
    );
    final licenseType = _requiredPatchValue(
      'aot_patch_license_type',
      platform.environment['SHOREBIRD_AOT_PATCH_LICENSE_TYPE'] ??
          shorebirdYaml.aotPatchLicenseType,
    );
    final sdkHash = _requiredPatchValue(
      'aot_patch_sdk_hash',
      platform.environment['SHOREBIRD_AOT_PATCH_SDK_HASH'] ??
          shorebirdYaml.aotPatchSdkHash ??
          manifest['sdk_hash'] as String?,
    );
    final configuredBaseHash =
        platform.environment['SHOREBIRD_AOT_PATCH_BASE_SNAPSHOT_HASH'] ??
        shorebirdYaml.aotPatchBaseSnapshotHash;
    if (configuredBaseHash != null && configuredBaseHash != baselineHash) {
      logger.err(
        'Configured base snapshot hash differs from the released '
        'baseline supplement.',
      );
      throw ProcessExit(ExitCode.usage.code);
    }
    final baseSnapshotHash = baselineHash;
    final baseFlavorId =
        platform.environment['SHOREBIRD_AOT_PATCH_BASE_FLAVOR_ID'] ??
        shorebirdYaml.aotPatchBaseFlavorId ??
        manifest['base_flavor_id'] as String?;
    final baseLicenseType =
        platform.environment['SHOREBIRD_AOT_PATCH_BASE_LICENSE_TYPE'] ??
        shorebirdYaml.aotPatchBaseLicenseType ??
        manifest['base_license_type'] as String?;
    final obfuscationMapHash =
        platform.environment['SHOREBIRD_AOT_PATCH_OBFUSCATION_MAP_HASH'] ??
        shorebirdYaml.aotPatchObfuscationMapHash;
    final offlineExpiresAt = _normalizeOptionalIso8601Utc(
      platform.environment['SHOREBIRD_AOT_PATCH_OFFLINE_EXPIRES_AT'] ??
          shorebirdYaml.aotPatchOfflineExpiresAt,
    );

    for (final entry in <String, String?>{
      'sdk_hash': sdkHash,
      'base_flavor_id': baseFlavorId,
      'base_license_type': baseLicenseType,
      'key_id': keyId,
    }.entries) {
      if (manifest[entry.key] != entry.value) {
        logger.err(
          'Interpreter baseline policy differs from patch ${entry.key}.',
        );
        throw ProcessExit(ExitCode.usage.code);
      }
    }
    final metadata = open_patch.PatchMetadata(
      appId: appId,
      appBuildId: appBuildId,
      baseFlavorId: _emptyToNull(baseFlavorId),
      baseLicenseType: _emptyToNull(baseLicenseType),
      flavorId: flavorId,
      licenseType: licenseType,
      sdkHash: sdkHash,
      baseSnapshotHash: baseSnapshotHash,
      patchSnapshotHash: open_patch.sha256Hex(patchSnapshot),
      targetOs: 'ios',
      targetArch: 'arm64',
      runtimeMode: open_patch.runtimeModeDartBytecodeInterpreter,
      obfuscationMapHash: _emptyToNull(obfuscationMapHash),
      offlineExpiresAt: offlineExpiresAt,
    );
    final artifact = open_patch.linkArtifacts(
      baseSnapshot: const [],
      patchSnapshot: patchSnapshot,
      metadata: metadata,
      forceFullSnapshot: true,
    );
    final encrypted = open_patch.encryptArtifact(
      artifact: artifact,
      keyId: keyId,
      key: open_patch.readKey(keyHex),
      nonce: _readOrCreateNonce(),
    );

    final outputFile = File(_interpreterPatchOutputPath)
      ..createSync(recursive: true)
      ..writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(encrypted.toJson()),
      );
    final emptyBaseDirectory = Directory.systemTemp.createTempSync();
    final progress = logger.progress('Creating interpreter patch transport');
    try {
      final emptyBase = File(p.join(emptyBaseDirectory.path, 'empty'))
        ..writeAsBytesSync(const []);
      // The updater always inflates zstd+bipatch downloads. Diffing against an
      // empty base produces a full replacement independent of its native base.
      // createDiffBundle signs the reconstructed AES envelope, not the diff.
      final bundle = await createDiffBundle(
        arch: Arch.arm64,
        releaseArtifactPath: emptyBase.path,
        patchArtifactPath: outputFile.path,
        progress: progress,
        podfileLockHash: interpreterPodfileLockHash,
      );
      progress.complete();
      return {Arch.arm64: bundle};
    } finally {
      emptyBaseDirectory.deleteTemporarySync();
    }
  }

  /// Builds native diff-check artifacts using the immutable released policy.
  Future<T> withInterpreterBaselineBuild<T>(Future<T> Function() build) async {
    if (iosPatchRuntimeMode != open_patch.runtimeModeDartBytecodeInterpreter) {
      return build();
    }
    if (obfuscate) {
      logger.err(
        'Obfuscated releases cannot receive iOS interpreter body patches. '
        'Create an interpreter release without --obfuscate.',
      );
      throw ProcessExit(ExitCode.usage.code);
    }
    final baseline = _baselineBytecode();
    final manifest = _baselineManifest(baseline);
    final previous = artifactBuilder.iosInterpreterBuildEnvironment;
    artifactBuilder.iosInterpreterBuildEnvironment = {
      ...previous,
      'SHOREBIRD_AOT_BASE_SNAPSHOT_HASH': open_patch.sha256Hex(
        baseline.readAsBytesSync(),
      ),
      for (final key in const {
        'APP_BUILD_ID': 'compiled_app_build_id',
        'BASE_FLAVOR_ID': 'base_flavor_id',
        'BASE_LICENSE_TYPE': 'base_license_type',
        'SDK_HASH': 'sdk_hash',
        'KEY_ID': 'key_id',
        'FLAVOR_ID': 'flavor_id',
        'LICENSE_TYPE': 'license_type',
        'OBFUSCATION_MAP_HASH': 'obfuscation_map_hash',
      }.entries)
        'SHOREBIRD_AOT_PATCH_${key.key}': manifest[key.value] as String? ?? '',
    };
    try {
      return await build();
    } finally {
      artifactBuilder.iosInterpreterBuildEnvironment = previous;
    }
  }

  /// Compiles bytecode using the public SDK, or honors a configured payload.
  Future<void> buildInterpreterBytecodePatch(List<String> buildArgs) async {
    final shorebirdYaml = shorebirdEnv.getShorebirdYaml();
    final baseline = _baselineBytecode();
    final manifest = _baselineManifest(baseline);
    final configuredBytecodePath = _configuredInterpreterBytecodePath(
      shorebirdYaml,
    );
    if (configuredBytecodePath != null) {
      logger.info(
        'Using configured iOS interpreter bytecode patch: '
        '${_projectRelativeFile(configuredBytecodePath).path}.',
      );
      return;
    }

    await IosBytecodeBuilder(
      projectRoot: projectRoot,
      target: target,
      flavor: flavor,
    ).build(
      outputPath: _interpreterPatchBytecodeOutputPath,
      buildArgs: buildArgs,
      patchBase: baseline,
      structuralUpdates: IosBytecodeBuilder.structuralUpdatesForManifest(
        manifest,
      ),
    );
  }

  Map<String, Object?> _baselineManifest(File baseline) {
    final file = File(
      p.join(baseline.parent.path, IosBytecodeBuilder.manifestFileName),
    );
    if (!file.existsSync()) {
      logger.err(
        'Interpreter release supplement has no baseline identity manifest.',
      );
      throw ProcessExit(ExitCode.usage.code);
    }
    final manifest = (jsonDecode(file.readAsStringSync()) as Map)
        .cast<String, Object?>();
    if (manifest['version'] != 1) {
      logger.err('Unsupported interpreter baseline manifest version.');
      throw ProcessExit(ExitCode.usage.code);
    }
    IosBytecodeBuilder.validateStructuralProfile(
      shorebirdEnv.getShorebirdYaml(),
      manifest,
    );
    return manifest;
  }

  File _baselineBytecode() {
    final directory = releaseSupplementDirectory;
    final baseline = directory == null
        ? null
        : File(p.join(directory.path, IosBytecodeBuilder.baselineFileName));
    if (baseline == null || !baseline.existsSync()) {
      logger.err(
        'This release has no interpreter baseline bytecode supplement. '
        'Create a new interpreter release before patching it.',
      );
      throw ProcessExit(ExitCode.usage.code);
    }
    return baseline;
  }

  String? _configuredInterpreterBytecodePath(ShorebirdYaml? shorebirdYaml) {
    return _emptyToNull(
      platform.environment['SHOREBIRD_IOS_INTERPRETER_PATCH_PATH'] ??
          shorebirdYaml?.aotPatchBytecodePath,
    );
  }

  File _projectRelativeFile(String path) {
    if (p.isAbsolute(path)) {
      return File(path);
    }
    return File(p.join(projectRoot.path, path));
  }

  String _requiredPatchValue(String name, String? value) {
    if (value == null || value.trim().isEmpty) {
      logger.err('Missing required iOS interpreter patch value: $name.');
      throw ProcessExit(ExitCode.usage.code);
    }
    return value.trim();
  }

  String? _emptyToNull(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    return value.trim();
  }

  String? _normalizeOptionalIso8601Utc(String? value) {
    final trimmed = _emptyToNull(value);
    if (trimmed == null) return null;
    final parsed = DateTime.tryParse(trimmed);
    if (parsed == null) {
      logger.err('Invalid aot_patch_offline_expires_at value: $trimmed.');
      throw ProcessExit(ExitCode.usage.code);
    }
    return parsed.toUtc().toIso8601String();
  }

  List<int> _readOrCreateNonce() {
    final nonceHex = platform.environment['SHOREBIRD_AOT_PATCH_NONCE_HEX'];
    if (nonceHex != null && nonceHex.trim().isNotEmpty) {
      return open_patch.readNonce(nonceHex);
    }
    final random = Random.secure();
    return List<int>.generate(12, (_) => random.nextInt(256));
  }

  bool _looksLikeNativeExecutable(List<int> bytes) {
    if (bytes.length < 4) return false;
    if (bytes[0] == 0x7f &&
        bytes[1] == 0x45 &&
        bytes[2] == 0x4c &&
        bytes[3] == 0x46) {
      return true;
    }
    final magic = bytes
        .take(4)
        .fold<int>(0, (value, byte) => (value << 8) | byte);
    return const {
      0xfeedface,
      0xfeedfacf,
      0xcefaedfe,
      0xcffaedfe,
      0xcafebabe,
      0xbebafeca,
    }.contains(magic);
  }
}
