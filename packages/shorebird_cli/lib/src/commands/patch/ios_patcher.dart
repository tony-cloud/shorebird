import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:meta/meta.dart';
import 'package:open_aot_patch_tools/open_aot_patch_tools.dart' as open_patch;
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/archive/archive.dart';
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/commands/patch/apple_patcher_mixin.dart';
import 'package:shorebird_cli/src/commands/patch/patcher.dart';
import 'package:shorebird_cli/src/common_arguments.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/doctor.dart';
import 'package:shorebird_cli/src/executables/executables.dart';
import 'package:shorebird_cli/src/extensions/arg_results.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/platform/platform.dart';
import 'package:shorebird_cli/src/release_type.dart';
import 'package:shorebird_cli/src/shorebird_artifacts.dart';
import 'package:shorebird_cli/src/shorebird_documentation.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_flutter.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:shorebird_cli/src/validators/validators.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';

/// {@template ios_patcher}
/// Functions to create an iOS patch.
/// {@endtemplate}
class IosPatcher extends Patcher
    with ApplePatcherMixin, ApplePodfileLockPatcherMixin {
  /// {@macro ios_patcher}
  IosPatcher({
    required super.argResults,
    required super.argParser,
    required super.flavor,
    required super.target,
  });

  String get _aotOutputPath =>
      p.join(shorebirdEnv.buildDirectory.path, 'out.aot');

  String get _vmcodeOutputPath =>
      p.join(shorebirdEnv.buildDirectory.path, 'out.vmcode');

  String get _appDillCopyPath =>
      p.join(shorebirdEnv.buildDirectory.path, 'app.dill');

  String get _interpreterPatchOutputPath =>
      p.join(shorebirdEnv.buildDirectory.path, 'ios_interpreter_patch.vmcode');

  String get _interpreterPatchBytecodeOutputPath => p.join(
    shorebirdEnv.buildDirectory.path,
    'ios_interpreter_patch.bytecode',
  );

  static const _flutterVersionDefine = 'FLUTTER_VERSION';
  static const _flutterChannelDefine = 'FLUTTER_CHANNEL';
  static const _flutterGitUrlDefine = 'FLUTTER_GIT_URL';
  static const _flutterFrameworkRevisionDefine = 'FLUTTER_FRAMEWORK_REVISION';
  static const _flutterEngineRevisionDefine = 'FLUTTER_ENGINE_REVISION';
  static const _flutterDartVersionDefine = 'FLUTTER_DART_VERSION';
  static const _flutterReservedDefines = [
    _flutterVersionDefine,
    _flutterChannelDefine,
    _flutterGitUrlDefine,
    _flutterFrameworkRevisionDefine,
    _flutterEngineRevisionDefine,
    _flutterDartVersionDefine,
    'FLUTTER_ENABLED_FEATURE_FLAGS',
  ];
  static const _runtimeFeatureFlags = [
    (
      configSetting: 'enable-windowing',
      environmentOverride: 'FLUTTER_WINDOWING',
      runtimeId: 'windowing',
    ),
    (
      configSetting: 'enable-accessibility-evaluations',
      environmentOverride: 'FLUTTER_ACCESSIBILITY_EVALUATIONS',
      runtimeId: 'accessibility_evaluations',
    ),
  ];

  /// The last build's link percentage.
  @visibleForTesting
  double? lastBuildLinkPercentage;

  /// The last build's link metadata.
  @visibleForTesting
  Json? lastBuildLinkMetadata;

  @override
  double? get linkPercentage => lastBuildLinkPercentage;

  @override
  Json? get linkMetadata => lastBuildLinkMetadata;

  @override
  ReleaseType get releaseType => ReleaseType.ios;

  @override
  String get primaryReleaseArtifactArch => 'xcarchive';

  @override
  String? get supplementaryReleaseArtifactArch => 'ios_supplement';

  @override
  List<Validator> get applePlatformValidators => doctor.iosCommandValidators;

  @override
  String? get localPodfileLockHash => shorebirdEnv.iosPodfileLockHash;

  @override
  String get podfileLockRelativePath => 'ios/Podfile.lock';

  @override
  Future<void> assertArgsAreValid() async {
    final exportOptionsPlistFile = argResults.file(
      CommonArguments.exportOptionsPlistArg.name,
    );
    if (exportOptionsPlistFile != null) {
      try {
        assertValidExportOptionsPlist(exportOptionsPlistFile);
      } on InvalidExportOptionsPlistException catch (error) {
        logger.err(error.message);
        throw ProcessExit(ExitCode.usage.code);
      }
    }
  }

  @override
  Future<File> buildPatchArtifact({String? releaseVersion}) async {
    final shouldCodesign = argResults['codesign'] == true;
    final (flutterVersionAndRevision, flutterVersion) = await (
      shorebirdFlutter.getVersionAndRevision(),
      shorebirdFlutter.getVersion(),
    ).wait;

    if ((flutterVersion ?? minimumSupportedIosFlutterVersion) <
        minimumSupportedIosFlutterVersion) {
      logger.err('''
iOS patches are not supported with Flutter versions older than $minimumSupportedIosFlutterVersion.
For more information see: ${supportedFlutterVersionsUrl.toLink()}''');
      throw ProcessExit(ExitCode.software.code);
    }

    final buildArgs = [
      ...argResults.forwardedArgs,
      ...extraBuildArgs,
      ...buildNameAndNumberArgsFromReleaseVersion(releaseVersion),
    ];

    // If buildIpa is called with a different codesign value than the
    // release was, we will erroneously report native diffs.
    final ipaBuildResult = await artifactBuilder.buildIpa(
      codesign: shouldCodesign,
      flavor: flavor,
      target: target,
      args: buildArgs,
      base64PublicKey: argResults.encodedPublicKey,
    );

    final runtimeMode = _iosPatchRuntimeMode;
    if (runtimeMode == open_patch.runtimeModeNativeAot) {
      if (!_allowsNativeIosAotPatch) {
        logger.err(
          '''
iOS native AOT patch artifacts are disabled by default because they require mapping downloaded native snapshot text as executable memory.
Set SHOREBIRD_IOS_NATIVE_AOT_PATCH=1 only for development-device validation.''',
        );
        throw ProcessExit(ExitCode.software.code);
      }
      if (splitDebugInfoPath != null) {
        Directory(splitDebugInfoPath!).createSync(recursive: true);
      }
      await artifactBuilder.buildElfAotSnapshot(
        appDillPath: ipaBuildResult.kernelFile.path,
        outFilePath: _aotOutputPath,
        genSnapshotArtifact: ShorebirdArtifact.genSnapshotIos,
        additionalArgs: [
          ...ApplePatcherMixin.splitDebugInfoArgs(splitDebugInfoPath),
          ...obfuscationGenSnapshotArgs,
        ],
      );
    } else if (runtimeMode != open_patch.runtimeModeDartBytecodeInterpreter) {
      logger.err('Unsupported iOS patch runtime mode: $runtimeMode');
      throw ProcessExit(ExitCode.usage.code);
    }
    if (runtimeMode == open_patch.runtimeModeDartBytecodeInterpreter) {
      await _buildInterpreterBytecodePatch(buildArgs);
    }

    // Copy the kernel file to the build directory so that it can be used
    // to generate a patch.
    ipaBuildResult.kernelFile.copySync(_appDillCopyPath);

    return artifactManager.getXcarchiveDirectory()!.zipToTempFile();
  }

  @override
  Future<Map<Arch, PatchArtifactBundle>> createPatchArtifacts({
    required String appId,
    required int releaseId,
    required File releaseArtifact,
    Directory? supplementDirectory,
    String? releaseVersion,
  }) async {
    // Verify that we have built a patch .xcarchive
    if (artifactManager.getXcarchiveDirectory()?.path == null) {
      logger.err('Unable to find .xcarchive directory');
      throw ProcessExit(ExitCode.software.code);
    }

    final runtimeMode = _iosPatchRuntimeMode;
    if (runtimeMode == open_patch.runtimeModeDartBytecodeInterpreter) {
      return _createInterpreterPatchArtifacts(
        appId: appId,
        releaseVersion: releaseVersion,
      );
    }
    if (runtimeMode != open_patch.runtimeModeNativeAot) {
      logger.err('Unsupported iOS patch runtime mode: $runtimeMode');
      throw ProcessExit(ExitCode.usage.code);
    }
    if (!_allowsNativeIosAotPatch) {
      logger.err(
        '''
iOS native AOT patch artifacts are disabled by default because they require mapping downloaded native snapshot text as executable memory.
Use the open interpreter route (`aot_patch_runtime_mode: dart-bytecode-interpreter`) for App Store-safe patches.
Set SHOREBIRD_IOS_NATIVE_AOT_PATCH=1 only for development-device validation.''',
      );
      throw ProcessExit(ExitCode.software.code);
    }

    final unzipProgress = logger.progress('Extracting release artifact');

    late final String releaseXcarchivePath;
    {
      final tempDir = Directory.systemTemp.createTempSync();
      await artifactManager.extractZip(
        zipFile: releaseArtifact,
        outputDirectory: tempDir,
      );
      releaseXcarchivePath = tempDir.path;
    }

    final releaseSupplementDir =
        supplementDirectory ?? Directory.systemTemp.createTempSync();

    unzipProgress.complete();
    final appDirectory = artifactManager.getIosAppDirectory(
      xcarchiveDirectory: Directory(releaseXcarchivePath),
    );
    if (appDirectory == null) {
      logger.err('Unable to find release artifact .app directory');
      throw ProcessExit(ExitCode.software.code);
    }
    final releaseArtifactFile = File(
      p.join(appDirectory.path, 'Frameworks', 'App.framework', 'App'),
    );

    final useLinker = AotTools.usesLinker(shorebirdEnv.flutterRevision);
    if (useLinker) {
      apple.copySupplementFilesToSnapshotDirs(
        releaseSupplementDir: releaseSupplementDir,
        releaseSnapshotDir: releaseArtifactFile.parent,
        patchSupplementDir: shorebirdEnv.iosSupplementDirectory,
        patchSnapshotDir: shorebirdEnv.buildDirectory,
      );

      final result = await apple.runLinker(
        kernelFile: File(_appDillCopyPath),
        releaseArtifact: releaseArtifactFile,
        splitDebugInfoArgs: [
          ...ApplePatcherMixin.splitDebugInfoArgs(splitDebugInfoPath),
          ...obfuscationGenSnapshotArgs,
        ],
        aotOutputFile: File(_aotOutputPath),
        vmCodeFile: File(_vmcodeOutputPath),
        ddMaxBytes: int.tryParse(
          platform.environment['SHOREBIRD_PATCH_DD_MAX_BYTES'] ?? '',
        ),
      );
      final linkPercentage = result.linkPercentage;
      final exitCode = result.exitCode;
      if (exitCode != ExitCode.success.code) throw ProcessExit(exitCode);
      if (linkPercentage != null &&
          linkPercentage < Patcher.linkPercentageWarningThreshold) {
        logger.warn(Patcher.lowLinkPercentageWarning(linkPercentage));
      }
      lastBuildLinkPercentage = linkPercentage;
      lastBuildLinkMetadata = result.linkMetadata;
    }

    final patchBuildFile = File(useLinker ? _vmcodeOutputPath : _aotOutputPath);

    final File patchFile;
    if (useLinker && await aotTools.isGeneratePatchDiffBaseSupported()) {
      final patchBaseProgress = logger.progress('Generating patch diff base');
      final analyzeSnapshotPath = shorebirdArtifacts.getArtifactPath(
        artifact: ShorebirdArtifact.analyzeSnapshotIos,
      );

      final File patchBaseFile;
      try {
        // If the aot_tools executable supports the dump_blobs command, we
        // can generate a stable diff base and use that to create a patch.
        patchBaseFile = await aotTools.generatePatchDiffBase(
          analyzeSnapshotPath: analyzeSnapshotPath,
          releaseSnapshot: releaseArtifactFile,
        );
        patchBaseProgress.complete();
      } on Exception catch (error) {
        patchBaseProgress.fail('$error');
        throw ProcessExit(ExitCode.software.code);
      }

      patchFile = File(
        await artifactManager.createDiff(
          releaseArtifactPath: patchBaseFile.path,
          patchArtifactPath: patchBuildFile.path,
        ),
      );
    } else {
      patchFile = patchBuildFile;
    }

    final patchFileSize = patchFile.statSync().size;
    final hash = sha256.convert(patchBuildFile.readAsBytesSync()).toString();
    final hashSignature = await signHash(hash);

    return {
      Arch.arm64: PatchArtifactBundle(
        arch: 'aarch64',
        path: patchFile.path,
        hash: hash,
        size: patchFileSize,
        hashSignature: hashSignature,
        podfileLockHash: shorebirdEnv.iosPodfileLockHash,
      ),
    };
  }

  String get _iosPatchRuntimeMode {
    final environmentMode =
        platform.environment['SHOREBIRD_IOS_PATCH_RUNTIME_MODE'];
    if (environmentMode != null && environmentMode.trim().isNotEmpty) {
      return environmentMode.trim();
    }
    if (_allowsNativeIosAotPatch) {
      return open_patch.runtimeModeNativeAot;
    }
    return shorebirdEnv.getShorebirdYaml()?.aotPatchRuntimeMode ??
        open_patch.runtimeModeDartBytecodeInterpreter;
  }

  bool get _allowsNativeIosAotPatch {
    final value = platform.environment['SHOREBIRD_IOS_NATIVE_AOT_PATCH'];
    return value == '1' || value == 'true' || value == 'yes';
  }

  Future<Map<Arch, PatchArtifactBundle>> _createInterpreterPatchArtifacts({
    required String appId,
    required String? releaseVersion,
  }) async {
    final shorebirdYaml = shorebirdEnv.getShorebirdYaml();
    if (shorebirdYaml == null) {
      logger.err('Unable to find shorebird.yaml for iOS interpreter patch.');
      throw ProcessExit(ExitCode.software.code);
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
          shorebirdYaml.aotPatchKeyId,
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
          shorebirdYaml.aotPatchSdkHash,
    );
    final baseSnapshotHash = _requiredPatchValue(
      'aot_patch_base_snapshot_hash',
      platform.environment['SHOREBIRD_AOT_PATCH_BASE_SNAPSHOT_HASH'] ??
          shorebirdYaml.aotPatchBaseSnapshotHash,
    );
    final baseFlavorId =
        platform.environment['SHOREBIRD_AOT_PATCH_BASE_FLAVOR_ID'] ??
        shorebirdYaml.aotPatchBaseFlavorId;
    final baseLicenseType =
        platform.environment['SHOREBIRD_AOT_PATCH_BASE_LICENSE_TYPE'] ??
        shorebirdYaml.aotPatchBaseLicenseType;
    final obfuscationMapHash =
        platform.environment['SHOREBIRD_AOT_PATCH_OBFUSCATION_MAP_HASH'] ??
        shorebirdYaml.aotPatchObfuscationMapHash;
    final offlineExpiresAt = _normalizeOptionalIso8601Utc(
      platform.environment['SHOREBIRD_AOT_PATCH_OFFLINE_EXPIRES_AT'] ??
          shorebirdYaml.aotPatchOfflineExpiresAt,
    );

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
    final patchFileSize = outputFile.statSync().size;
    final hash = sha256.convert(outputFile.readAsBytesSync()).toString();
    final hashSignature = await signHash(hash);
    logger.info(
      'Created iOS interpreter patch artifact at ${outputFile.path}.',
    );

    return {
      Arch.arm64: PatchArtifactBundle(
        arch: 'aarch64',
        path: outputFile.path,
        hash: hash,
        size: patchFileSize,
        hashSignature: hashSignature,
        podfileLockHash: shorebirdEnv.iosPodfileLockHash,
      ),
    };
  }

  Future<void> _buildInterpreterBytecodePatch(List<String> buildArgs) async {
    final shorebirdYaml = shorebirdEnv.getShorebirdYaml();
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

    final inputFile = _projectRelativeFile(
      target ?? p.join('lib', 'main.dart'),
    );
    if (!inputFile.existsSync()) {
      logger.err(
        'Unable to find Dart entrypoint for iOS interpreter patch: '
        '${inputFile.path}',
      );
      throw ProcessExit(ExitCode.usage.code);
    }

    final packageConfigFile = File(
      p.join(projectRoot.path, '.dart_tool', 'package_config.json'),
    );
    await artifactBuilder.buildDartBytecodeSnapshot(
      inputFilePath: inputFile.path,
      outFilePath: _interpreterPatchBytecodeOutputPath,
      packageConfigPath: packageConfigFile.existsSync()
          ? packageConfigFile.path
          : null,
      dartDefines: _dartDefinesForBytecode(buildArgs),
      experiments: _buildArgValues(buildArgs, 'enable-experiment'),
    );
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

  List<String> _dartDefinesForBytecode(List<String> buildArgs) {
    final defines = <String>[];
    for (final defineFilePath in _buildArgValues(
      buildArgs,
      CommonArguments.dartDefineFromFileArg.name,
    )) {
      defines.addAll(_readDartDefineFile(_projectRelativeFile(defineFilePath)));
    }
    defines.addAll(
      _buildArgValues(buildArgs, CommonArguments.dartDefineArg.name),
    );
    if (flavor != null &&
        !defines.any((define) => define.startsWith('FLUTTER_APP_FLAVOR='))) {
      defines.add('FLUTTER_APP_FLAVOR=$flavor');
    }
    _assertNoReservedFlutterDefines(defines);
    defines.addAll(_flutterVersionDartDefinesForBytecode());
    if (_enabledRuntimeFeatureDefinesForBytecode() case final featureDefine?) {
      defines.add(featureDefine);
    }
    return defines;
  }

  void _assertNoReservedFlutterDefines(List<String> defines) {
    for (final reservedDefine in _flutterReservedDefines) {
      if (defines.any((define) => define.startsWith(reservedDefine))) {
        logger.err(
          '$reservedDefine is used by Flutter and cannot be set using --'
          '${CommonArguments.dartDefineArg.name} or --'
          '${CommonArguments.dartDefineFromFileArg.name}.',
        );
        throw ProcessExit(ExitCode.usage.code);
      }
    }
  }

  List<String> _flutterVersionDartDefinesForBytecode() {
    final versionFile = File(
      p.join(
        shorebirdEnv.flutterDirectory.path,
        'bin',
        'cache',
        'flutter.version.json',
      ),
    );
    if (!versionFile.existsSync()) return const [];

    final Json versionJson;
    try {
      versionJson = (jsonDecode(versionFile.readAsStringSync()) as Map)
          .cast<String, Object?>();
    } on Object catch (error) {
      logger.err('Unable to parse ${versionFile.path}: $error');
      throw ProcessExit(ExitCode.software.code);
    }

    String? stringValue(String key) {
      final value = versionJson[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    String? shortRevision(String key) {
      final revision = stringValue(key);
      if (revision == null) return null;
      return revision.length > 10 ? revision.substring(0, 10) : revision;
    }

    return [
      if (stringValue('frameworkVersion') case final value?)
        '$_flutterVersionDefine=$value',
      if (stringValue('channel') case final value?)
        '$_flutterChannelDefine=$value',
      if (stringValue('repositoryUrl') case final value?)
        '$_flutterGitUrlDefine=$value',
      if (shortRevision('frameworkRevision') case final value?)
        '$_flutterFrameworkRevisionDefine=$value',
      if (shortRevision('engineRevision') case final value?)
        '$_flutterEngineRevisionDefine=$value',
      if (stringValue('dartSdkVersion') case final value?)
        '$_flutterDartVersionDefine=$value',
    ];
  }

  String? _enabledRuntimeFeatureDefinesForBytecode() {
    final channel = _flutterVersionJsonString('channel');
    final runtimeIds = <String>[];
    for (final feature in _runtimeFeatureFlags) {
      if (_isRuntimeFeatureEnabledForBytecode(
        configSetting: feature.configSetting,
        environmentOverride: feature.environmentOverride,
        channel: channel,
      )) {
        runtimeIds.add(feature.runtimeId);
      }
    }
    if (runtimeIds.isEmpty) return null;
    return 'FLUTTER_ENABLED_FEATURE_FLAGS=${runtimeIds.join(',')}';
  }

  bool _isRuntimeFeatureEnabledForBytecode({
    required String configSetting,
    required String environmentOverride,
    required String? channel,
  }) {
    if (channel == 'stable' || channel == 'beta') {
      return false;
    }
    return _projectFeatureConfig(configSetting) ??
        _globalFeatureConfig(configSetting) ??
        _environmentFeatureConfig(environmentOverride) ??
        false;
  }

  bool? _projectFeatureConfig(String configSetting) {
    final config = shorebirdEnv.getPubspecYaml()?.flutter?['config'];
    if (config == null) return null;
    if (config is! Map) {
      logger.err(
        'The "config" property of "flutter" in pubspec.yaml must be a map.',
      );
      throw ProcessExit(ExitCode.usage.code);
    }
    return _featureConfigBool(
      config[configSetting],
      name: configSetting,
      source: 'flutter: config: in pubspec.yaml',
    );
  }

  bool? _globalFeatureConfig(String configSetting) {
    return _featureConfigBool(
      shorebirdFlutter.getConfig()[configSetting],
      name: configSetting,
      source: 'flutter config',
    );
  }

  bool? _environmentFeatureConfig(String environmentOverride) {
    final value = platform.environment[environmentOverride];
    if (value == null) return null;
    return value.toLowerCase() == 'true';
  }

  bool? _featureConfigBool(
    Object? value, {
    required String name,
    required String source,
  }) {
    if (value == null || value == '(Not set)') return null;
    if (value is bool) return value;
    if (value is String) {
      if (value.toLowerCase() == 'true') return true;
      if (value.toLowerCase() == 'false') return false;
    }
    logger.err(
      'The "$name" property in $source must be a boolean, but got $value.',
    );
    throw ProcessExit(ExitCode.usage.code);
  }

  String? _flutterVersionJsonString(String key) {
    final versionFile = File(
      p.join(
        shorebirdEnv.flutterDirectory.path,
        'bin',
        'cache',
        'flutter.version.json',
      ),
    );
    if (!versionFile.existsSync()) return null;
    try {
      final versionJson = (jsonDecode(versionFile.readAsStringSync()) as Map)
          .cast<String, Object?>();
      final value = versionJson[key];
      return value is String && value.isNotEmpty ? value : null;
    } on Object catch (error) {
      logger.err('Unable to parse ${versionFile.path}: $error');
      throw ProcessExit(ExitCode.software.code);
    }
  }

  List<String> _buildArgValues(List<String> args, String name) {
    final values = <String>[];
    final longOption = '--$name';
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == longOption && i + 1 < args.length) {
        values.add(args[++i]);
      } else if (arg.startsWith('$longOption=')) {
        values.add(arg.substring(longOption.length + 1));
      } else if (name == CommonArguments.dartDefineArg.name &&
          arg.startsWith('-D') &&
          arg.length > 2) {
        values.add(arg.substring(2));
      }
    }
    return values;
  }

  List<String> _readDartDefineFile(File file) {
    if (!file.existsSync()) {
      logger.err(
        'Did not find the file passed to --'
        '${CommonArguments.dartDefineFromFileArg.name}: ${file.path}',
      );
      throw ProcessExit(ExitCode.usage.code);
    }

    final raw = file.readAsStringSync();
    if (raw.trimLeft().startsWith('{')) {
      try {
        final map = (jsonDecode(raw) as Map).cast<String, Object?>();
        return [
          for (final entry in map.entries) '${entry.key}=${entry.value}',
        ];
      } on FormatException catch (error) {
        logger.err(
          'Unable to parse Dart define file ${file.path}: $error',
        );
        throw ProcessExit(ExitCode.usage.code);
      }
    }

    final defines = <String>[];
    for (final line in const LineSplitter().convert(raw)) {
      final define = _parseDartDefineEnvLine(line);
      if (define != null) defines.add(define);
    }
    return defines;
  }

  String? _parseDartDefineEnvLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) return null;
    final separatorIndex = trimmed.indexOf('=');
    if (separatorIndex <= 0) {
      logger.err(
        'Invalid Dart define file line for --'
        '${CommonArguments.dartDefineFromFileArg.name}: $line',
      );
      throw ProcessExit(ExitCode.usage.code);
    }
    final key = trimmed.substring(0, separatorIndex).trim();
    var value = trimmed.substring(separatorIndex + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.substring(1, value.length - 1);
    }
    return '$key=$value';
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

  @override
  Future<String> extractReleaseVersionFromArtifact(File artifact) async {
    final archivePath = artifactManager.getXcarchiveDirectory()?.path;
    if (archivePath == null) {
      logger.err('Unable to find .xcarchive directory');
      throw ProcessExit(ExitCode.software.code);
    }

    final plistFile = File(p.join(archivePath, 'Info.plist'));
    if (!plistFile.existsSync()) {
      logger.err('No Info.plist file found at ${plistFile.path}.');
      throw ProcessExit(ExitCode.software.code);
    }

    final plist = Plist(file: plistFile);
    try {
      return plist.versionNumber;
    } on Exception catch (error) {
      logger.err(
        'Failed to determine release version from ${plistFile.path}: $error',
      );
      throw ProcessExit(ExitCode.software.code);
    }
  }
}
