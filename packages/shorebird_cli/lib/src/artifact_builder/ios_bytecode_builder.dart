import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/common_arguments.dart';
import 'package:shorebird_cli/src/config/shorebird_yaml.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_flutter.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:yaml/yaml.dart';

/// Resolves identical source, SDK, defines, and feature flags for iOS bytecode.
class IosBytecodeBuilder {
  /// Creates the shared release/patch bytecode compiler.
  IosBytecodeBuilder({required this.projectRoot, this.target, this.flavor});

  /// Project root containing the package configuration.
  final Directory projectRoot;

  /// Dart entrypoint, relative to the project unless absolute.
  final String? target;

  /// Selected Flutter flavor.
  final String? flavor;

  /// Full baseline bytecode stored only in the private release supplement.
  static const baselineFileName = 'baseline.bytecode';

  /// Baseline identity and compatibility metadata in the release supplement.
  static const manifestFileName = 'baseline.json';

  /// Compiles a baseline or a delta using the release's immutable profile.
  Future<File> build({
    required String outputPath,
    required List<String> buildArgs,
    List<String>? dartDefines,
    File? patchBase,
    bool structuralUpdates = false,
  }) async {
    final input = _projectRelativeFile(target ?? p.join('lib', 'main.dart'));
    if (!input.existsSync()) {
      logger.err(
        'Unable to find Dart entrypoint for iOS bytecode: ${input.path}',
      );
      throw ProcessExit(ExitCode.usage.code);
    }
    File(outputPath).parent.createSync(recursive: true);
    final packages = File(
      p.join(projectRoot.path, '.dart_tool', 'package_config.json'),
    );
    return artifactBuilder.buildDartBytecodeSnapshot(
      inputFilePath: input.path,
      outFilePath: outputPath,
      packageConfigPath: packages.path,
      dartDefines: dartDefines ?? dartDefinesForBytecode(buildArgs),
      experiments: _buildArgValues(buildArgs, 'enable-experiment'),
      patchBasePath: patchBase?.path,
      structuralUpdates: structuralUpdates,
    );
  }

  File _projectRelativeFile(String path) =>
      File(p.isAbsolute(path) ? path : p.join(projectRoot.path, path));

  static const _flutterVersionDefine = 'FLUTTER_VERSION';
  static const _flutterChannelDefine = 'FLUTTER_CHANNEL';
  static const _flutterGitUrlDefine = 'FLUTTER_GIT_URL';
  static const _flutterFrameworkRevisionDefine = 'FLUTTER_FRAMEWORK_REVISION';
  static const _flutterEngineRevisionDefine = 'FLUTTER_ENGINE_REVISION';
  static const _flutterDartVersionDefine = 'FLUTTER_DART_VERSION';
  static const _flutterVersionDefines = [
    _flutterVersionDefine,
    _flutterChannelDefine,
    _flutterGitUrlDefine,
    _flutterFrameworkRevisionDefine,
    _flutterEngineRevisionDefine,
    _flutterDartVersionDefine,
  ];
  static const _flutterReservedDefines = [
    ..._flutterVersionDefines,
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

  /// Reads the explicit capability, retaining old v1 manifests as body-only.
  static bool structuralUpdatesForManifest(Map<String, Object?> manifest) {
    if (manifest.containsKey('structural_updates') &&
        manifest['structural_updates'] is! bool) {
      throw ArtifactBuildException(
        'Interpreter baseline structural_updates must be a boolean.',
      );
    }
    return manifest['structural_updates'] == true;
  }

  /// Prevents patch source configuration from changing the released profile.
  static bool validateStructuralProfile(
    ShorebirdYaml? source,
    Map<String, Object?> manifest,
  ) {
    final enabled = structuralUpdatesForManifest(manifest);
    if ((source?.aotPatchStructuralUpdates ?? false) != enabled) {
      throw ArtifactBuildException(
        'aot_patch_structural_updates differs from the released interpreter '
        'baseline. Match the release profile, or create a new release to '
        'change its structural update capability.',
      );
    }
    return enabled;
  }

  /// Cross-checks supplement identity against a bundled policy, when present.
  static void validateCompiledPolicy(
    File release,
    Map<String, Object?> manifest,
  ) {
    final structuralUpdates = structuralUpdatesForManifest(manifest);
    // Some legacy release archives do not contain bundled Flutter assets.
    if (!release.existsSync() || release.lengthSync() < 4) {
      if (structuralUpdates) {
        throw ArtifactBuildException(
          'Structural updates require a release with a compiled profile.',
        );
      }
      return;
    }
    final stream = InputFileStream(release.path);
    try {
      final archive = ZipDecoder().decodeStream(stream);
      var foundPolicy = false;
      for (final file in archive.files) {
        if (!file.isFile ||
            !file.name.endsWith('/flutter_assets/shorebird.yaml') ||
            file.name.contains('simulator')) {
          continue;
        }
        final yaml = loadYaml(utf8.decode(file.content as List<int>));
        foundPolicy = true;
        if (yaml is! YamlMap) {
          throw const FormatException('Invalid compiled policy');
        }
        final structural = yaml['aot_patch_structural_updates'];
        if ((yaml.containsKey('aot_patch_structural_updates') &&
                structural is! bool) ||
            (structural ?? false) != structuralUpdates) {
          throw ArtifactBuildException(
            'Release compiled structural update profile differs from '
            'baseline supplement.',
          );
        }
        for (final entry in const {
          'app_id': 'app_id',
          'aot_patch_sdk_hash': 'sdk_hash',
          'aot_patch_base_snapshot_hash': 'base_snapshot_hash',
          'aot_patch_base_flavor_id': 'base_flavor_id',
          'aot_patch_base_license_type': 'base_license_type',
          'aot_patch_key_id': 'key_id',
        }.entries) {
          if (yaml[entry.key] != manifest[entry.value]) {
            throw ArtifactBuildException(
              'Release compiled policy differs from baseline supplement: '
              '${entry.key}.',
            );
          }
        }
        final buildId = yaml['aot_patch_app_build_id'];
        if (buildId != null && buildId != manifest['app_build_id']) {
          throw ArtifactBuildException(
            'Release compiled app build id differs from baseline supplement.',
          );
        }
        if (yaml['aot_patch_runtime_mode'] != 'dart-bytecode-interpreter' ||
            yaml['patch_verification'] != 'strict' ||
            yaml['patch_response_verification'] != 'required' ||
            yaml['patch_public_key'] is! String ||
            (yaml['patch_public_key'] as String).trim().isEmpty ||
            yaml['aot_patch_key_hex'] != null) {
          throw ArtifactBuildException(
            'Release does not contain a secure interpreter '
            'verification policy.',
          );
        }
      }
      if (structuralUpdates && !foundPolicy) {
        throw ArtifactBuildException(
          'Structural updates require a release with a compiled profile.',
        );
      }
    } on FormatException {
      throw ArtifactBuildException(
        'Unable to parse the release compiled interpreter policy.',
      );
    } finally {
      stream.closeSync();
    }
  }

  /// Resolves project and Flutter defines identically for both builds.
  List<String> dartDefinesForBytecode(
    List<String> buildArgs, {
    Map<String, Object?>? baselineManifest,
  }) {
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
    defines.addAll(
      _releasedFlutterVersionDefines(baselineManifest) ??
          _flutterVersionDartDefinesForBytecode(),
    );
    if (_enabledRuntimeFeatureDefinesForBytecode() case final featureDefine?) {
      defines.add(featureDefine);
    }
    return defines;
  }

  List<String>? _releasedFlutterVersionDefines(
    Map<String, Object?>? manifest,
  ) {
    if (manifest == null || !manifest.containsKey('dart_defines')) return null;
    final recorded = manifest['dart_defines'];
    if (recorded is! List || recorded.any((value) => value is! String)) {
      throw ArtifactBuildException(
        'Interpreter baseline dart_defines must be a list of strings.',
      );
    }
    if (sha256.convert(utf8.encode(jsonEncode(recorded))).toString() !=
        manifest['defines_sha256']) {
      throw ArtifactBuildException(
        'Interpreter baseline Dart defines do not match defines_sha256.',
      );
    }
    // Application defines may change for patches. Flutter version constants
    // must retain the values compiled into the baseline static initializers.
    return recorded.cast<String>().where((define) {
      return _flutterVersionDefines.any((name) => define.startsWith('$name='));
    }).toList();
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
}
