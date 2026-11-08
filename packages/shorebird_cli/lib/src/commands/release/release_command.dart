import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:meta/meta.dart';
import 'package:open_aot_patch_tools/open_aot_patch_tools.dart' as open_patch;
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/archive_analysis/native_selection_archive.dart';
import 'package:shorebird_cli/src/archive_analysis/release_selection_archive.dart';
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_builder/build_trace_session.dart';
import 'package:shorebird_cli/src/artifact_builder/ios_bytecode_builder.dart';
import 'package:shorebird_cli/src/artifact_builder/ios_replacement_host.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/cache.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/code_signer.dart';
import 'package:shorebird_cli/src/commands/release/native_selection_publication.dart';
import 'package:shorebird_cli/src/commands/release/release.dart';
import 'package:shorebird_cli/src/common_arguments.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/extensions/arg_results.dart';
import 'package:shorebird_cli/src/extensions/string.dart';
import 'package:shorebird_cli/src/json_output.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/metadata/metadata.dart';
import 'package:shorebird_cli/src/patch_verification.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/platform/platform.dart';
import 'package:shorebird_cli/src/release_type.dart';
import 'package:shorebird_cli/src/security_profile.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';
import 'package:shorebird_cli/src/shorebird_documentation.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_flutter.dart';
import 'package:shorebird_cli/src/shorebird_validator.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:shorebird_cli/src/version.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';

/// A function that resolves a [Releaser] for a given [ReleaseType].
typedef ResolveReleaser = Releaser Function(ReleaseType releaseType);

/// {@template release_command}
/// Creates a new app release for the specified platform(s).
/// {@endtemplate}
class ReleaseCommand extends ShorebirdCommand {
  /// {@macro release_command}
  ReleaseCommand({ResolveReleaser? resolveReleaser}) {
    _resolveReleaser = resolveReleaser ?? getReleaser;
    argParser
      ..addMultiOption(
        CommonArguments.dartDefineArg.name,
        help: CommonArguments.dartDefineArg.description,
      )
      ..addMultiOption(
        CommonArguments.dartDefineFromFileArg.name,
        help: CommonArguments.dartDefineFromFileArg.description,
      )
      ..addOption(
        'target',
        abbr: 't',
        help: 'The main entrypoint file of the application.',
      )
      ..addOption(
        'flavor',
        help: 'The product flavor to use when building the app.',
      )
      ..addOption(
        CommonArguments.buildNameArg.name,
        help: CommonArguments.buildNameArg.description,
        defaultsTo: CommonArguments.buildNameArg.defaultValue,
      )
      ..addOption(
        CommonArguments.buildNumberArg.name,
        help: CommonArguments.buildNumberArg.description,
        defaultsTo: CommonArguments.buildNumberArg.defaultValue,
      )
      ..addFlag(
        'codesign',
        help: 'Codesign the app bundle or XCFrameworks (iOS and macOS only).',
        defaultsTo: true,
      )
      ..addFlag(
        'stage-only',
        negatable: false,
        help:
            'Build, upload and verify native protocol-2 packages '
            'while leaving the platform draft.',
      )
      ..addFlag(
        'dry-run',
        abbr: 'n',
        negatable: false,
        help: 'Validate but do not upload the release.',
      )
      ..addOption(
        CommonArguments.exportOptionsPlistArg.name,
        help: CommonArguments.exportOptionsPlistArg.description,
      )
      ..addOption(
        CommonArguments.exportMethodArg.name,
        allowed: ExportMethod.values.map((e) => e.argName),
        help: CommonArguments.exportMethodArg.description,
        allowedHelp: {
          for (final method in ExportMethod.values)
            method.argName: method.description,
        },
      )
      ..addOption(
        'flutter-version',
        defaultsTo: 'latest',
        help: '''
The Flutter version to use when building the app (e.g: 3.16.3).
This option also accepts Flutter commit hashes (e.g. 611a4066f1).
Also accepts the following special values:
  * "latest" builds using the latest stable Flutter version.
  * "system" uses the version reported by the `flutter` on your PATH.
  * "fvm" uses the version fvm resolves for this project.''',
      )
      ..addOption(
        'artifact',
        help:
            '''The type of artifact to generate. Only relevant for Android releases.''',
        allowed: ['aab', 'apk'],
        defaultsTo: 'aab',
        allowedHelp: {
          'aab': 'Android App Bundle',
          'apk': 'Android Package Kit',
        },
      )
      ..addMultiOption(
        'platforms',
        abbr: 'p',
        help: 'The platform(s) to build this release for.',
        allowed: ReleaseType.values.map((e) => e.cliName).toList(),
      )
      ..addFlag(
        'split-per-abi',
        help:
            'Whether to split the APKs per ABIs (Android only). '
            'To learn more, see: https://developer.android.com/studio/build/configure-apk-splits#configure-abi-split',
        hide: true,
        negatable: false,
      )
      ..addFlag(
        CommonArguments.noConfirmArg.name,
        help: CommonArguments.noConfirmArg.description,
        negatable: false,
        hide: true,
      )
      ..addOption(
        'release-version',
        help: '''
The version of the associated release (e.g. "1.0.0"). This should be the version
of the iOS app that is using this module. (aar and ios-framework only)''',
      )
      ..addMultiOption(
        'target-platform',
        help: 'The Android target platform(s) for which the app is compiled.',
        defaultsTo: Arch.values.map((arch) => arch.targetPlatformCliArg),
        allowed: Arch.values.map((arch) => arch.targetPlatformCliArg),
      )
      ..addOption(
        CommonArguments.publicKeyArg.name,
        help: CommonArguments.publicKeyArg.description,
      )
      ..addOption(
        CommonArguments.publicKeyCmd.name,
        help: CommonArguments.publicKeyCmd.description,
      )
      ..addFlag(
        CommonArguments.patchSigningArg.name,
        defaultsTo: true,
        help: CommonArguments.patchSigningArg.description,
      )
      ..addOption(
        CommonArguments.splitDebugInfoArg.name,
        help: CommonArguments.splitDebugInfoArg.description,
      )
      ..addFlag(
        CommonArguments.obfuscateArg.name,
        help: CommonArguments.obfuscateArg.description,
        negatable: false,
      )
      ..addOption(
        CommonArguments.ddMaxBytesArg.name,
        defaultsTo: '10000',
        hide: true,
        help: CommonArguments.ddMaxBytesArg.description,
      )
      ..addOption(
        CommonArguments.aotLinkDdMaxBytesArg.name,
        hide: true,
        help: CommonArguments.aotLinkDdMaxBytesArg.description,
      )
      ..addOption(
        securityProfileOption,
        defaultsTo: SecurityProfile.legacy.name,
        valueHelp: 'legacy|hardened',
        help:
            'The security profile of this release, fixed for all of its '
            'patches.\n'
            'legacy (default) keeps the current behavior. hardened requires a '
            'Shorebird toolchain built hardened and its pinned Flutter, the '
            'Shorebird-managed patch signing key (no --public-key-path, '
            '--public-key-cmd or --no-patch-signing), and an https base_url '
            'in shorebird.yaml.\n'
            '"${SecurityProfile.reservedDiversified}" is reserved and not yet '
            'supported.',
      );
  }

  /// The name of the option that selects the release's security profile.
  static const securityProfileOption = 'security-profile';

  late final ResolveReleaser _resolveReleaser;

  @override
  String get description =>
      'Creates a shorebird release for the provided target platforms.';

  @override
  String get name => 'release';

  @override
  Future<int> run() async {
    final releaseTypes = releaseTypesOrUsageError(
      siblingCommand: 'releases',
      versionHint: _versionHint,
    );

    // One Release can carry several platforms, so releases are collected by
    // id: each platform's pass re-fetches the release, and the last fetch is
    // the one whose platform statuses are complete.
    final releases = <int, Release>{};
    for (final releaseType in releaseTypes) {
      final release = await createRelease(_resolveReleaser(releaseType));
      releases[release.id] = release;
    }

    if (isJsonMode) {
      emitJsonSuccess({
        'app_id': appId,
        'platforms': [
          for (final type in releaseTypes) type.releasePlatform.name,
        ],
        'releases': [for (final release in releases.values) release.toJson()],
      });
    }

    return ExitCode.success.code;
  }

  /// Returns a [Releaser] for the given [ReleaseType].
  @visibleForTesting
  Releaser getReleaser(ReleaseType releaseType) {
    switch (releaseType) {
      case ReleaseType.aar:
        return AarReleaser(argResults: results, flavor: flavor, target: target);
      case ReleaseType.android:
        return AndroidReleaser(
          argResults: results,
          flavor: flavor,
          target: target,
        );
      case ReleaseType.ios:
        return IosReleaser(argResults: results, flavor: flavor, target: target);
      case ReleaseType.iosFramework:
        return IosFrameworkReleaser(
          argResults: results,
          flavor: flavor,
          target: target,
        );
      case ReleaseType.linux:
        return LinuxReleaser(
          argResults: results,
          flavor: flavor,
          target: target,
        );
      case ReleaseType.macos:
        return MacosReleaser(
          argResults: results,
          flavor: flavor,
          target: target,
        );
      case ReleaseType.windows:
        return WindowsReleaser(
          argResults: results,
          flavor: flavor,
          target: target,
        );
    }
  }

  /// The shorebird app ID for the current project.
  String get appId => shorebirdEnv.getShorebirdYaml()!.getAppId(flavor: flavor);

  /// The build flavor, if provided.
  String? get flavor => results.findOption('flavor', argParser: argParser);

  /// `--release-version` is only valid for aar and ios-framework releases;
  /// other platforms take their version from `--build-name` and
  /// `--build-number` (or the pubspec).
  String? _versionHint(String version) {
    final platform = results.rest.first;
    if (platform == ReleaseType.aar.cliName ||
        platform == ReleaseType.iosFramework.cliName) {
      return null;
    }
    final plus = version.indexOf('+');
    if (plus == -1) return 'Did you mean --build-name=$version?';
    return 'Did you mean --build-name=${version.substring(0, plus)} '
        '--build-number=${version.substring(plus + 1)}?';
  }

  /// The target script, if provided.
  late final String? target = resolveTarget();

  /// The flutter version specified.
  String get flutterVersionArg => results['flutter-version'] as String;

  String? _resolvedFlutterVersionArg;

  /// [flutterVersionArg] with the "system" and "fvm" aliases resolved to a
  /// concrete Flutter version (e.g. `3.32.4`) by asking that Flutter which
  /// version it is. Any other value is returned unchanged.
  ///
  /// The resolved version is then looked up like any other, so we build with
  /// Shorebird's fork at the matching version, and a version Shorebird doesn't
  /// support fails the same way an explicitly requested one does.
  ///
  /// The lookup is only performed once per command.
  Future<String> resolveFlutterVersionArg() async {
    if (_resolvedFlutterVersionArg case final resolved?) return resolved;

    final String command;
    final Future<String?> Function() getVersion;
    switch (flutterVersionArg) {
      case 'system':
        command = 'flutter --version';
        getVersion = shorebirdFlutter.getSystemVersion;
      case 'fvm':
        // `getFvmVersion` may ask fvm more than one thing, so name the tool
        // rather than a single command line.
        command = 'fvm';
        getVersion = shorebirdFlutter.getFvmVersion;
      default:
        return _resolvedFlutterVersionArg = flutterVersionArg;
    }

    final String? version;
    try {
      version = await getVersion();
    } on Exception catch (error) {
      logger.err('''
Unable to determine the Flutter version from `$command`.
$error''');
      throw ProcessExit(ExitCode.software.code);
    }

    if (version == null) {
      logger.err(
        'Unable to parse a Flutter version from the output of `$command`.',
      );
      throw ProcessExit(ExitCode.software.code);
    }

    logger.info('Using Flutter $version, as reported by `$command`.');
    return _resolvedFlutterVersionArg = version;
  }

  /// The build name specified via `--build-name`.
  String? get buildName =>
      results[CommonArguments.buildNameArg.name] as String?;

  /// The build number specified via `--build-number.
  String? get buildNumber =>
      results[CommonArguments.buildNumberArg.name] as String?;

  /// The workflow to create a new release for a Shorebird app.
  ///
  /// Returns the published [Release]. A dry run does not return: it exits
  /// the process with success once the build has been checked.
  ///
  /// Expectations for methods invoked by this command:
  ///  - They perform their own logging. If an error occurs, they are
  ///    responsible for properly logging the error, cleaning up running
  ///    [Progress]es, etc.
  ///  - They handle their own exceptions and exit with a non-zero exit code if
  ///    an error occurs *instead of* throwing an exception.
  @visibleForTesting
  Future<Release> createRelease(Releaser releaser) async {
    await releaser.assertPreconditions();
    await assertArgsAreValid(releaser);
    await _validateFlavors(releaser);

    await cache.updateAll();

    // This command handles logging, we don't need to provide our own
    // progress, error logs, etc.
    final app = await codePushClientWrapper.getApp(appId: appId);
    final targetFlutterRevision = await _installTargetFlutter();
    await _ensureRequestedVersionIsReleasable(
      releaser: releaser,
      flutterRevision: targetFlutterRevision,
    );

    final releaseFlutterShorebirdEnv = shorebirdEnv.copyWith(
      flutterRevisionOverride: targetFlutterRevision,
    );
    return await runScoped(
      () => _buildAndPublishRelease(
        releaser: releaser,
        app: app,
        flutterRevision: targetFlutterRevision,
      ),
      values: {shorebirdEnvRef.overrideWith(() => releaseFlutterShorebirdEnv)},
    );
  }

  /// Exits with [ExitCode.config] if [flavor] doesn't match the project's
  /// flavors for [releaser]'s platform.
  Future<void> _validateFlavors(Releaser releaser) async {
    try {
      await shorebirdValidator.validateFlavors(
        flavorArg: flavor,
        releasePlatform: releaser.releaseType.releasePlatform,
      );
    } on ValidationFailedException catch (e) {
      throw PreconditionFailedExit(e);
    }
  }

  /// Resolves the Flutter revision to release with, installs it, and returns
  /// it.
  Future<String> _installTargetFlutter() async {
    final targetFlutterRevision = await resolveTargetFlutterRevision();
    try {
      await shorebirdFlutter.installRevision(revision: targetFlutterRevision);
    } on Exception catch (error, stackTrace) {
      logger
        ..err('Unable to install Flutter $targetFlutterRevision.\n$error')
        ..detail('$stackTrace');
      throw ProcessExit(ExitCode.software.code);
    }
    return targetFlutterRevision;
  }

  /// If a user explicitly specified --build-name (and optionally
  /// --build-number), we ensure that the version is releasable to avoid
  /// unnecessarily waiting for a build.
  Future<void> _ensureRequestedVersionIsReleasable({
    required Releaser releaser,
    required String flutterRevision,
  }) async {
    final version = buildName;
    if (version == null) return;
    await ensureVersionIsReleasable(
      version: buildNumber != null ? '$version+$buildNumber' : version,
      flutterRevision: flutterRevision,
      releasePlatform: releaser.releaseType.releasePlatform,
    );
  }

  /// Builds the release with [flutterRevision] and publishes it. Runs with
  /// [shorebirdEnv] scoped to [flutterRevision].
  Future<Release> _buildAndPublishRelease({
    required Releaser releaser,
    required AppMetadata app,
    required String flutterRevision,
  }) async {
    assertIosInterpreterReleaseConfiguration(releaser);
    await cache.updateAll();
    await _assertPatchVerificationChecksSignatures();

    // Set up build tracing for this platform before any flutter build /
    // aot_tools / gen_snapshot call runs. Version-gated inside
    // prepareBuildTrace — a no-op on older Flutter pins. Finalized at
    // the end of finalizeRelease, after upload, so uploaded metadata
    // reflects the whole command.
    await artifactBuilder.prepareBuildTrace(
      platform: releaser.releaseType.releasePlatform.name,
    );

    final releaseArtifact = await _buildReleaseArtifacts(releaser);
    final releaseVersion = await releaser.getReleaseVersion(
      releaseArtifactRoot: releaseArtifact,
    );

    assertCompiledReleaseVersion(releaser, releaseVersion);

    // Ensure we can create a release from what we've built.
    await ensureVersionIsReleasable(
      version: releaseVersion,
      flutterRevision: flutterRevision,
      releasePlatform: releaser.releaseType.releasePlatform,
    );

    if (results['dry-run'] == true) {
      _exitDryRun(
        releaser: releaser,
        releaseVersion: releaseVersion,
        flutterRevision: flutterRevision,
      );
    }

    await printReleaseSummary(
      app: app,
      releaseVersion: releaseVersion,
      flutterVersion: flutterRevision,
      releasePlatform: releaser.releaseType.releasePlatform,
      signing: releaser.signing,
    );

    final release = await _publishRelease(
      releaser: releaser,
      releaseVersion: releaseVersion,
    );
    return _refreshReleaseForJson(release);
  }

  /// Exits with [ExitCode.config] if shorebird.yaml asks for
  /// `patch_verification: install_only` on a Flutter build whose updater
  /// never checks patch signatures in that mode (since updater#352).
  /// Runs with [shorebirdEnv] scoped to the release's Flutter revision.
  Future<void> _assertPatchVerificationChecksSignatures() async {
    final patchVerification = shorebirdEnv
        .getShorebirdYaml()
        ?.patchVerification;
    if (patchVerification != PatchVerification.installOnly) return;
    if (!installOnlySkipsSignatureCheck(shorebirdEnv.shorebirdEngineRevision)) {
      return;
    }
    final flutterVersion = await shorebirdFlutter.getVersionAndRevision();
    final failure = ValidationFailedException(
      message:
          '`patch_verification: install_only` in shorebird.yaml does not '
          'check patch signatures with Flutter $flutterVersion.',
      hint:
          'Remove `patch_verification` from shorebird.yaml (or set it to '
          '`strict`), so patches are verified each time the app launches, or '
          'release with a Flutter '
          'version that checks signatures in install_only mode, such as '
          '--flutter-version=3.41.8.',
    );
    logger
      ..err(failure.message)
      ..info(failure.hint);
    throw PreconditionFailedExit(failure);
  }

  /// Builds the release artifacts, exiting with [ExitCode.software] if the
  /// build fails.
  Future<FileSystemEntity> _buildReleaseArtifacts(Releaser releaser) async {
    final flutterVersionString = await shorebirdFlutter.getVersionAndRevision();
    logger.info(
      '''Building ${releaser.artifactDisplayName} with Flutter $flutterVersionString''',
    );
    try {
      return await releaser.buildReleaseArtifacts();
    } on ArtifactBuildException catch (e) {
      logger.err(e.message);
      if (!e.fixRecommendation.isNullOrEmpty) {
        logger.info(e.fixRecommendation);
      }
      throw ProcessExit(ExitCode.software.code);
    } on ProcessExit {
      // A step before the build (such as fetching the patch signing key)
      // already reported why it stopped, and an ApiErrorExit carries the
      // server's error for --json.
      rethrow;
    } on Exception catch (e) {
      logger.err('Failed to build release artifacts: $e');
      throw ProcessExit(ExitCode.software.code);
    }
  }

  /// Reports that a dry run found no issues and exits with success.
  Never _exitDryRun({
    required Releaser releaser,
    required String releaseVersion,
    required String flutterRevision,
  }) {
    if (isJsonMode) {
      emitJsonSuccess({
        'dry_run': true,
        'app_id': appId,
        'platform': releaser.releaseType.releasePlatform.name,
        'release_version': releaseVersion,
        'flutter_revision': flutterRevision,
      });
    } else {
      logger
        ..info('No issues detected.')
        ..info('The server may enforce additional checks.');
    }
    throw ProcessExit(ExitCode.success.code);
  }

  /// Creates or reuses the release for [releaseVersion], uploads its
  /// artifacts, marks it active, and tells the user how to patch it.
  Future<Release> _publishRelease({
    required Releaser releaser,
    required String releaseVersion,
  }) async {
    final release = await getOrCreateRelease(
      version: releaseVersion,
      releasePlatform: releaser.releaseType.releasePlatform,
    );
    await prepareRelease(release: release, releaser: releaser);
    await releaser.uploadReleaseArtifacts(release: release, appId: appId);
    await releaser.uploadSupplementArtifact(
      appId: appId,
      releaseId: release.id,
      releaseVersion: release.version,
    );
    if (release.selectionProtocol == 2) {
      await _registerSelectionScope(release, releaser);
    }
    if (results['stage-only'] != true) {
      await finalizeRelease(release: release, releaser: releaser);
    }

    logger
      ..success('''

✅ ${results['stage-only'] == true ? 'Staged' : 'Published'} Release ${release.version}!''')
      ..info(releaser.postReleaseInstructions);

    printPatchInstructions(
      releaser: releaser,
      releaseVersion: releaseVersion,
      releaseType: releaser.releaseType,
      flavor: flavor,
      target: target,
    );
    return release;
  }

  Future<void> _registerSelectionScope(
    Release release,
    Releaser releaser,
  ) async {
    final client = codePushClientWrapper.codePushClient;
    final platform = releaser.releaseType.releasePlatform;
    if (NativeSelectionArchive.platforms.contains(platform.name)) {
      await NativeSelectionPublication.verify(
        appId: appId,
        release: release,
        platform: platform,
        arches: releaser.nativeSelectionArches,
        expectedNativePatchMaxBytes: shorebirdEnv
            .getShorebirdYaml()
            ?.nativePatchMaxBytes,
        expectedSigningKeyId: releaser.signing?.keyId,
        register: true,
      );
      return;
    }
    final artifacts = await client.getReleaseArtifacts(
      appId: appId,
      releaseId: release.id,
      platform: platform,
    );
    final primary = artifacts.singleWhere(
      (a) =>
          a.arch == (platform == ReleasePlatform.macos ? 'app' : 'xcarchive'),
    );
    final supplement = artifacts.singleWhere(
      (a) => a.arch == releaser.supplementArtifactArch,
    );
    final signing = primary.signing;
    if (signing?.mode != 'managed' ||
        signing?.keyId == null ||
        signing?.keyId != releaser.signing?.keyId ||
        signing?.publicKeyPem == null ||
        supplement.signing != signing) {
      throw const FormatException(
        'Uploaded release artifacts differ from the managed build signing key',
      );
    }
    final expectedPublicKey = codeSigner.base64PublicKeyFromPem(
      signing!.publicKeyPem!,
    );
    final temp = Directory.systemTemp.createTempSync('shorebird-publication-');
    try {
      Future<File> retrieve(ReleaseArtifact artifact) async {
        final file = await artifactManager.downloadFile(
          Uri.parse(artifact.url),
          outputPath: '${temp.path}/${artifact.id}',
        );
        if (file.lengthSync() != artifact.size ||
            sha256.convert(file.readAsBytesSync()).toString() !=
                artifact.hash) {
          throw const FormatException(
            'Uploaded release archive hash/size mismatch',
          );
        }
        return file;
      }

      final packageFile = await retrieve(primary);
      final supplementFile = await retrieve(supplement);
      final scope = ReleaseSelectionArchive.verifyPackage(
        packageFile,
        appId: appId,
        version: release.version,
        platform: platform.name,
        expectedPublicKey: expectedPublicKey,
        arch: releaser.interpreterArchitecture.arch,
      );
      final manifest = ReleaseSelectionArchive.verifySupplement(
        supplementFile,
        scope,
      );
      IosBytecodeBuilder.validateCompiledPolicy(packageFile, manifest);
      await client.registerReleaseSelectionScope(
        appId: appId,
        releaseId: release.id,
        scope: scope,
        releaseArtifactId: primary.id,
        supplementArtifactId: supplement.id,
      );
    } finally {
      temp.deleteSync(recursive: true);
    }
  }

  /// Returns [release] as it is now, for the JSON envelope.
  ///
  /// The Release in hand predates finalizeRelease, so its status for this
  /// platform still reads draft. A caller reading the envelope should see the
  /// release as it is now, which costs one fetch and is only paid when there
  /// is an envelope to fill.
  ///
  /// Best-effort, because by this point the release is published: a refresh
  /// that fails must not turn a run that succeeded into a failed one.
  /// getRelease would do exactly that -- it exits the process, and does it
  /// with a message about publishing patches, which is not what the user just
  /// ran. Falling back to the release in hand costs the envelope a stale
  /// status, no more.
  Future<Release> _refreshReleaseForJson(Release release) async {
    if (!isJsonMode) return release;
    try {
      final refreshed = await codePushClientWrapper.maybeGetRelease(
        appId: appId,
        releaseVersion: release.version,
      );
      return refreshed ?? release;
    } on Exception {
      return release;
    }
  }

  /// Validates arguments that are common to all release types.
  Future<void> assertArgsAreValid(Releaser releaser) async {
    assertPublicKeyArgsValid();
    assertSecurityProfileAdmitted(releaser);

    final protocol = shorebirdEnv.getShorebirdYaml()?.selectionProtocol ?? 1;
    final nativeSelection =
        protocol == 2 &&
        NativeSelectionArchive.platforms.contains(
          releaser.releaseType.releasePlatform.name,
        );
    if (results['stage-only'] == true && (protocol != 2 || !nativeSelection)) {
      usageException('--stage-only requires a native protocol-2 release.');
    }
    final supportedProfile =
        protocol != 2 ||
        (nativeSelection
            ? const <String?>{
                null,
                'native-aot',
              }.contains(shorebirdEnv.getShorebirdYaml()?.aotPatchRuntimeMode)
            : const {
                    ReleaseType.ios,
                    ReleaseType.macos,
                  }.contains(releaser.releaseType) &&
                  shorebirdEnv.getShorebirdYaml()?.aotPatchRuntimeMode ==
                      'dart-bytecode-interpreter');
    if (protocol == 2 &&
        (!supportedProfile ||
            !results.patchSigningEnabled ||
            results.wasParsed(CommonArguments.publicKeyArg.name) ||
            results.wasParsed(CommonArguments.publicKeyCmd.name))) {
      usageException(
        'Protocol 2 publication requires a supported runtime profile '
        'with managed signing.',
      );
    }

    final shorebirdYaml = shorebirdEnv.getShorebirdYaml();
    final hasPublicKey =
        results.wasParsed(CommonArguments.publicKeyArg.name) ||
        results.wasParsed(CommonArguments.publicKeyCmd.name);
    if (hasPublicKey && !results.patchSigningEnabled) {
      usageException(
        '--no-${CommonArguments.patchSigningArg.name} builds a release whose '
        'patches are unsigned, so it cannot be combined with '
        '--${CommonArguments.publicKeyArg.name} or '
        '--${CommonArguments.publicKeyCmd.name}.',
      );
    }
    if (!results.patchSigningEnabled ||
        shorebirdYaml?.patchVerification == PatchVerification.installOnly) {
      final isIos = const {
        ReleaseType.ios,
        ReleaseType.iosFramework,
      }.contains(releaser.releaseType);
      if ((isIos &&
              _iosPatchRuntimeMode ==
                  open_patch.runtimeModeDartBytecodeInterpreter) ||
          (releaser.releaseType == ReleaseType.macos &&
              shorebirdYaml?.aotPatchRuntimeMode ==
                  open_patch.runtimeModeDartBytecodeInterpreter)) {
        final platformName = isIos ? 'iOS' : 'macOS';
        usageException(
          'Encrypted $platformName interpreter releases require patch signing '
          'and '
          'patch_verification: strict. Remove --no-patch-signing and '
          'patch_verification: install_only.',
        );
      }
    }
    if (shorebirdYaml?.patchVerification != null &&
        !results.patchSigningEnabled) {
      logger.warn(
        'patch_verification is set in shorebird.yaml but '
        '--no-${CommonArguments.patchSigningArg.name} builds a release whose '
        'patches are unsigned.\n'
        'patch_verification configuration will have no effect.',
      );
    }

    // The Flutter version this release will be built with: the CLI's pinned
    // revision unless --flutter-version says otherwise.
    final version = await shorebirdFlutter.resolveFlutterVersion(
      flutterVersionArg == 'latest'
          ? shorebirdEnv.flutterRevision
          : await resolveFlutterVersionArg(),
    );
    final minimumFlutterVersion = releaser.minimumFlutterVersion;
    if (version != null && version < minimumFlutterVersion) {
      logger.err('''
At least Flutter $minimumFlutterVersion is required to release with `${releaser.releaseType.cliName}`.
For more information see: ${supportedFlutterVersionsUrl.toLink()}''');
      throw ProcessExit(ExitCode.usage.code);
    }

    if (releaser.useObfuscation &&
        patchesLinkAgainstRelease(releaser.releaseType.releasePlatform) &&
        version != null &&
        version < minimumObfuscationFlutterVersion) {
      logger.err(
        'Obfuscation on '
        '${releaser.releaseType.releasePlatform.displayName} '
        'requires Flutter $minimumObfuscationFlutterVersion or later '
        '(current: $version).',
      );
      throw ProcessExit(ExitCode.unavailable.code);
    }

    // Ask the releaser to assert its own args are valid.
    await releaser.assertArgsAreValid();
  }

  /// The profile requested with `--security-profile`. Usage error for the
  /// reserved profile or an unknown value.
  SecurityProfile get requestedSecurityProfile {
    final value =
        results[securityProfileOption] as String? ??
        SecurityProfile.legacy.name;
    if (value == SecurityProfile.reservedDiversified) {
      usageException(
        '--$securityProfileOption=$value is reserved for a later version of '
        'the security contract and is not supported. Use legacy or hardened.',
      );
    }
    final profile = SecurityProfile.tryParse(value);
    if (profile == null) {
      usageException(
        '--$securityProfileOption must be legacy or hardened, not "$value".',
      );
    }
    return profile;
  }

  /// Release admission for the security profile (docs/HARDENING_CONTRACTS.md
  /// §2). Runs before anything is built, for every platform.
  ///
  /// The requested profile must match the installed toolchain's floor in both
  /// directions, the toolchain must not be a development toolchain, and the
  /// checked-in shorebird.yaml must not set the keys only the build writes.
  /// A hardened release additionally needs the Shorebird-managed signing key
  /// (no --no-patch-signing, no customer key: only managed signing lets the
  /// server authenticate patch-check responses, which hardened requires), the
  /// installed toolchain's pinned Flutter, and a shorebird.yaml that meets the
  /// hardened floor. [releaser] then fails closed if the managed key does not
  /// resolve (see [Releaser.requireManagedSigning]). On success, a hardened
  /// release's `flutter build`s receive SHOREBIRD_SECURITY_PROFILE and
  /// SHOREBIRD_TOOLCHAIN_ID; a legacy release's environment is unchanged.
  ///
  // TODO(hardening-p4): record security_profile and toolchain_id in the
  // release record and have the server reject mismatched patches
  // (docs/HARDENING_CONTRACTS.md §7).
  @visibleForTesting
  void assertSecurityProfileAdmitted(Releaser releaser) {
    final requested = requestedSecurityProfile;
    final toolchain = loadToolchainSecurityOrExit();

    if (toolchain.developmentExceptions) {
      _refuseRelease(
        'This Shorebird toolchain was built with development security '
        'exceptions, so it cannot build releases.',
        hint:
            'Install a production Shorebird toolchain (one whose '
            '${ToolchainSecurity.fileName} sets development_exceptions: '
            'false) and run the release again.',
      );
    }
    if (requested != toolchain.profile) {
      switch (requested) {
        case SecurityProfile.hardened:
          _refuseRelease(
            '--$securityProfileOption=hardened needs a hardened Shorebird '
            'toolchain, but this toolchain was not built hardened.',
            hint:
                'Release without --$securityProfileOption (legacy), or '
                'install a Shorebird toolchain built with the hardened '
                'profile.',
          );
        case SecurityProfile.legacy:
          _refuseRelease(
            'This Shorebird toolchain is hardened '
            '(${toolchain.toolchainId}), so it cannot build a legacy '
            'release.',
            hint:
                'Pass --$securityProfileOption=hardened, or use a legacy '
                'Shorebird toolchain.',
          );
      }
    }

    if (shorebirdEnv.getShorebirdProjectRoot() case final root?) {
      final file = File(p.join(root.path, 'shorebird.yaml'));
      if (file.existsSync()) {
        final reserved = reservedSecurityKeysIn(file.readAsStringSync());
        if (reserved.isNotEmpty) {
          _refuseRelease(
            'shorebird.yaml must not set ${reserved.join(', ')}: the build '
            'writes ${reserved.length == 1 ? 'it' : 'them'} into the bundled '
            'shorebird.yaml from --$securityProfileOption.',
            hint: 'Remove ${reserved.join(', ')} from shorebird.yaml.',
          );
        }
      }
    }

    if (requested == SecurityProfile.legacy) return;

    if (!results.patchSigningEnabled) {
      usageException(
        'A hardened release only accepts signed patches, so it cannot be '
        'built with --no-${CommonArguments.patchSigningArg.name}. Remove '
        '--no-${CommonArguments.patchSigningArg.name}: hardened releases '
        'embed the Shorebird-managed patch signing key.',
      );
    }
    if (results.wasParsed(CommonArguments.publicKeyArg.name) ||
        results.wasParsed(CommonArguments.publicKeyCmd.name)) {
      usageException(
        'A hardened release uses the Shorebird-managed patch signing key, so '
        'it cannot be combined with --${CommonArguments.publicKeyArg.name} '
        'or --${CommonArguments.publicKeyCmd.name}: with a customer key the '
        'server cannot authenticate patch-check responses, which hardened '
        'requires. Remove --${CommonArguments.publicKeyArg.name} and '
        '--${CommonArguments.publicKeyCmd.name}.',
      );
    }

    // toolchain_id describes only the installed toolchain, so a hardened
    // release must be built with its pinned Flutter.
    final flutterVersion = results['flutter-version'] as String? ?? 'latest';
    if (flutterVersion != 'latest' &&
        flutterVersion != shorebirdEnv.flutterRevision) {
      usageException(
        '--$securityProfileOption=hardened builds with the installed '
        "toolchain's own Flutter (${shorebirdEnv.flutterRevision}), because "
        'its toolchain_id describes only that toolchain. Remove '
        '--flutter-version=$flutterVersion.',
      );
    }

    final problems = hardenedShorebirdYamlProblems(
      shorebirdEnv.getShorebirdYaml(),
    );
    if (problems.isNotEmpty) {
      _refuseRelease(
        'shorebird.yaml does not meet the hardened profile:\n'
        '${problems.map((problem) => '  - $problem').join('\n')}',
        hint:
            'Fix shorebird.yaml, or release without '
            '--$securityProfileOption (legacy).',
      );
    }

    releaser.requireManagedSigning = true;
    artifactBuilder.securityBuildEnvironment = toolchain.buildEnvironment;
  }

  Never _refuseRelease(String message, {required String hint}) {
    final failure = ValidationFailedException(message: message, hint: hint);
    logger
      ..err(failure.message)
      ..info(hint);
    throw PreconditionFailedExit(failure);
  }

  String get _iosPatchRuntimeMode {
    final nativeOptIn = platform.environment['SHOREBIRD_IOS_NATIVE_AOT_PATCH'];
    final nativeEnabled = const {'1', 'true', 'yes'}.contains(nativeOptIn);
    final environmentMode = platform
        .environment['SHOREBIRD_IOS_PATCH_RUNTIME_MODE']
        ?.trim();
    if (environmentMode != null && environmentMode.isNotEmpty) {
      return environmentMode;
    }
    return (nativeEnabled ? open_patch.runtimeModeNativeAot : null) ??
        shorebirdEnv.getShorebirdYaml()?.aotPatchRuntimeMode ??
        open_patch.runtimeModeDartBytecodeInterpreter;
  }

  /// Ensures the scope sealed before compilation matches the built package.
  @visibleForTesting
  void assertCompiledReleaseVersion(Releaser releaser, String releaseVersion) {
    final configuredBuildId = shorebirdEnv
        .getShorebirdYaml()
        ?.aotPatchAppBuildId;
    if (((shorebirdEnv.getShorebirdYaml()?.selectionProtocol == 2 &&
                NativeSelectionArchive.platforms.contains(
                  releaser.releaseType.releasePlatform.name,
                )) ||
            (const {
                  ReleaseType.ios,
                  ReleaseType.iosFramework,
                  ReleaseType.macos,
                }.contains(releaser.releaseType) &&
                _iosPatchRuntimeMode ==
                    open_patch.runtimeModeDartBytecodeInterpreter)) &&
        configuredBuildId != null &&
        configuredBuildId != releaseVersion) {
      usageException(
        'aot_patch_app_build_id differs from the built release version. '
        'Set it to the exact built version, including its build number.',
      );
    }
  }

  /// Checks response-signing compatibility and the interpreter trust policy.
  /// Runs before building or creating a release on the server.
  @visibleForTesting
  void assertIosInterpreterReleaseConfiguration(Releaser releaser) {
    final macos = releaser.releaseType == ReleaseType.macos;
    final yaml = shorebirdEnv.getShorebirdYaml();
    if (macos &&
        ((yaml?.aotPatchFullReplacement ?? false) ||
            yaml?.aotPatchRuntimeMode ==
                open_patch.runtimeModeDartBytecodeInterpreter)) {
      if (!(yaml?.aotPatchFullReplacement ?? false) ||
          (yaml?.aotPatchStructuralUpdates ?? false) ||
          yaml?.aotPatchRuntimeMode !=
              open_patch.runtimeModeDartBytecodeInterpreter) {
        usageException(
          'macOS interpreter releases require full replacement without '
          'additive or body-only profiles.',
        );
      }
      try {
        validateMacosFullReplacementBuildArgs(results.forwardedArgs);
      } on ArtifactBuildException catch (error) {
        usageException(error.message);
      }
    }
    final interpreter =
        const {
              ReleaseType.ios,
              ReleaseType.iosFramework,
            }.contains(releaser.releaseType) &&
            _iosPatchRuntimeMode ==
                open_patch.runtimeModeDartBytecodeInterpreter ||
        releaser.releaseType == ReleaseType.macos &&
            yaml?.aotPatchRuntimeMode ==
                open_patch.runtimeModeDartBytecodeInterpreter;
    if (!interpreter) {
      final customerKey = results[CommonArguments.publicKeyArg.name] as String?;
      final customerCommand =
          results[CommonArguments.publicKeyCmd.name] as String?;
      final customerSigning = customerKey != null || customerCommand != null;
      if (customerSigning &&
          shorebirdEnv.getShorebirdYaml()?.patchResponseVerification !=
              PatchResponseVerification.optional) {
        usageException(
          'Customer-signed native releases require explicit '
          'patch_response_verification: optional in shorebird.yaml. The server '
          'does not hold the customer private key and cannot authenticate '
          'patch-check responses. Artifact signatures remain verified. Use '
          'managed signing to require authenticated responses; an explicit '
          'required policy cannot be downgraded automatically.',
        );
      }
      return;
    }
    final platformName = macos ? 'macOS' : 'iOS';
    if (results.wasParsed(CommonArguments.publicKeyArg.name) ||
        results.wasParsed(CommonArguments.publicKeyCmd.name)) {
      usageException(
        'Encrypted $platformName interpreter releases currently require '
        'managed signing '
        'to authenticate patch offers and rollback responses. Remove '
        '--public-key-path/--public-key-cmd and use the default managed key. '
        'Customer signing remains available for native AOT releases with '
        'explicit optional response verification.',
      );
    }
    if (releaser.useObfuscation) {
      usageException(
        '$platformName interpreter releases require stable Dart symbol names. '
        'Remove --obfuscate; obfuscated baselines cannot receive interpreter '
        'body patches.',
      );
    }
    final required = <String, String?>{
      'aot_patch_runtime_mode': yaml?.aotPatchRuntimeMode,
      'aot_patch_base_flavor_id': yaml?.aotPatchBaseFlavorId,
      'aot_patch_base_license_type': yaml?.aotPatchBaseLicenseType,
      'aot_patch_key_id': yaml?.aotPatchKeyId,
    };
    final missing = required.entries
        .where((entry) => entry.value == null || entry.value!.trim().isEmpty)
        .map((entry) => entry.key)
        .toList();
    if (missing.isNotEmpty) {
      usageException(
        'Missing $platformName interpreter baseline policy in shorebird.yaml: '
        '${missing.join(', ')}. Set aot_patch_runtime_mode to '
        'dart-bytecode-interpreter. The SDK id and baseline bytecode hash '
        'are derived during the release build. App id and release build '
        'version are resolved from the build automatically.',
      );
    }
    if (yaml!.aotPatchRuntimeMode !=
        open_patch.runtimeModeDartBytecodeInterpreter) {
      usageException(
        'Set aot_patch_runtime_mode: dart-bytecode-interpreter in '
        'shorebird.yaml so the release embeds its interpreter baseline policy.',
      );
    }
    if (yaml.aotPatchBaseSnapshotHash != null &&
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(yaml.aotPatchBaseSnapshotHash!)) {
      usageException(
        'aot_patch_base_snapshot_hash must be the lowercase SHA-256 hash '
        'of the baseline Dart bytecode (64 hexadecimal characters).',
      );
    }
  }

  /// Determines which Flutter version to use for the release. This will be
  /// either the version specified by the user or the version provided by
  /// [shorebirdEnv]. Will exit with [ExitCode.software] if the version
  /// specified by the user is not found/supported.
  Future<String> resolveTargetFlutterRevision() async {
    if (flutterVersionArg == 'latest') return shorebirdEnv.flutterRevision;

    final versionOrHash = await resolveFlutterVersionArg();

    // Fetch the latest remote refs so that release branch pointers
    // (e.g. flutter_release/3.38.5) are up to date.
    await shorebirdFlutter.fetchRemoteRefs();

    final String? revision;
    try {
      revision = await shorebirdFlutter.resolveFlutterRevision(versionOrHash);
    } on Exception catch (error) {
      logger.err('''
Unable to determine revision for Flutter version: $versionOrHash.
$error''');
      throw ProcessExit(ExitCode.software.code);
    }

    if (revision == null) {
      final openIssueLink = link(
        uri: Uri.parse(openShorebirdIssueUrl),
        message: 'open an issue',
      );
      logger.err('''
Version $versionOrHash not found. Please $openIssueLink to request a new version.
Use `shorebird flutter versions list` to list available versions.
''');
      throw ProcessExit(ExitCode.software.code);
    }

    return revision;
  }

  /// Asserts that a release with version [version] can be released using
  /// flutter revision [flutterRevision]. If a release has already been
  /// published with the given [version] for the platform [releasePlatform], or
  /// if a release already exists with [version] but was compiled with a
  /// different Flutter revision, an error will be thrown.
  Future<void> ensureVersionIsReleasable({
    required String version,
    required String flutterRevision,
    required ReleasePlatform releasePlatform,
  }) async {
    final existingRelease = await codePushClientWrapper.maybeGetRelease(
      appId: appId,
      releaseVersion: version,
    );

    if (existingRelease != null) {
      codePushClientWrapper.ensureReleaseIsNotActive(
        release: existingRelease,
        platform: releasePlatform,
      );

      // All artifacts associated with a given release must be built
      // with the same Flutter revision.
      if (existingRelease.flutterRevision != flutterRevision) {
        final flutterVersion = await shorebirdFlutter.getVersionForRevision(
          flutterRevision: flutterRevision,
        );

        final formattedCurrentReleaseVersion = shorebirdFlutter.formatVersion(
          revision: flutterRevision,
          version: flutterVersion,
        );

        final formattedExistingReleaseVersion = shorebirdFlutter.formatVersion(
          revision: existingRelease.flutterRevision,
          version: existingRelease.flutterVersion,
        );

        logger
          ..err('''
${styleBold.wrap(lightRed.wrap('A release with version $version already exists but was built using a different Flutter revision.'))}
''')
          ..info(
            '''

  Existing release built with: ${lightCyan.wrap(formattedExistingReleaseVersion)}
  Current release built with: ${lightCyan.wrap(formattedCurrentReleaseVersion)}

${styleBold.wrap(lightRed.wrap('All platforms for a given release must be built using the same Flutter revision.'))}

To resolve this issue, you can:
  * Re-run the release command with "${lightCyan.wrap('--flutter-version=${existingRelease.flutterRevision}')}".
  * Delete the existing release and re-run the release command with the desired Flutter version.
  * Bump the release version and re-run the release command with the desired Flutter version.''',
          );
        throw ProcessExit(ExitCode.software.code);
      }
    }
  }

  /// Prints a summary of the release to be created.
  Future<void> printReleaseSummary({
    required AppMetadata app,
    required String releaseVersion,
    required String flutterVersion,
    required ReleasePlatform releasePlatform,
    ArtifactSigningRequest? signing,
  }) async {
    final flutterVersionString = await shorebirdFlutter.getVersionAndRevision();
    // TODO(bryanoltman): include archs in the summary for android
    // (and other platforms?)
    final summary = [
      '''📱 App: ${lightCyan.wrap(app.displayName)} ${lightCyan.wrap('(${app.appId})')}''',
      if (flavor != null) '🍧 Flavor: ${lightCyan.wrap(flavor)}',
      '📦 Release Version: ${lightCyan.wrap(releaseVersion)}',
      '🕹️  Platform: ${lightCyan.wrap(releasePlatform.name)}',
      '🐦 Flutter Version: ${lightCyan.wrap(flutterVersionString)}',
      if (signing?.mode == ReleaseSigningMode.managed)
        '🔏 Patch Signing: ${lightCyan.wrap('Shorebird-managed key')}'
      else if (signing?.mode == ReleaseSigningMode.customer)
        '🔏 Patch Signing: ${lightCyan.wrap('your key')}'
      else if (signing?.mode == ReleaseSigningMode.unsigned)
        '🔏 Patch Signing: ${yellow.wrap('off')}',
    ];

    logger.info('''

${styleBold.wrap(lightGreen.wrap('🚀 Ready to create a new release!'))}

${summary.join('\n')}
''');
  }

  /// Fetches the release with version [version] from the server or creates a
  /// new release if none exists.
  Future<Release> getOrCreateRelease({
    required String version,
    required ReleasePlatform releasePlatform,
  }) async {
    final protocol = shorebirdEnv.getShorebirdYaml()?.selectionProtocol ?? 1;
    final existing = await codePushClientWrapper.maybeGetRelease(
      appId: appId,
      releaseVersion: version,
    );
    if (existing != null) {
      if (existing.selectionProtocol != protocol) {
        usageException(
          'selection_protocol differs from the immutable release. '
          'Use a new release version.',
        );
      }
      return existing;
    }
    return codePushClientWrapper.createRelease(
      appId: appId,
      version: version,
      flutterRevision: shorebirdEnv.flutterRevision,
      platform: releasePlatform,
      selectionProtocol: protocol == 2 ? 2 : null,
    );
  }

  /// Prepares the release by updating the release status to draft.
  Future<void> prepareRelease({
    required Release release,
    required Releaser releaser,
  }) async {
    if (release.selectionProtocol == 2 &&
        release.platforms[releaser.releaseType.releasePlatform]?.status !=
            null &&
        release.platforms[releaser.releaseType.releasePlatform]?.status !=
            ReleaseStatus.draft) {
      usageException(
        'A published protocol-2 platform cannot be rebuilt or drafted. '
        'Use a new version.',
      );
    }
    await codePushClientWrapper.updateReleaseStatus(
      appId: appId,
      releaseId: release.id,
      platform: releaser.releaseType.releasePlatform,
      status: ReleaseStatus.draft,
    );
  }

  /// Finalizes the release by updating the status to active.
  Future<void> finalizeRelease({
    required Release release,
    required Releaser releaser,
  }) async {
    // Write the build-trace summary now, after the release artifact has been
    // uploaded, so aggregate timings reflect the full command. No-op when
    // tracing wasn't set up (older Flutter pin).
    artifactBuilder.writeBuildTraceSummary();

    final hasPublicKey =
        results.wasParsed(CommonArguments.publicKeyArg.name) ||
        results.wasParsed(CommonArguments.publicKeyCmd.name);
    final baseMetadata = UpdateReleaseMetadata(
      releasePlatform: releaser.releaseType.releasePlatform,
      flutterVersionOverride: flutterVersionArg,
      includesPublicKey: hasPublicKey,
      environment: BuildEnvironmentMetadata(
        flutterRevision: shorebirdEnv.flutterRevision,
        operatingSystem: platform.operatingSystem,
        operatingSystemVersion: platform.operatingSystemVersion,
        shorebirdVersion: packageVersion,
        shorebirdYaml: shorebirdEnv.getShorebirdYaml()!,
        usesShorebirdCodePushPackage: shorebirdEnv.usesShorebirdCodePushPackage,
      ),
      // Attach the build-trace summary if the build produced one.
      // Null for older Flutter pins without the --shorebird-trace flag
      // or when trace parsing failed; uploader sends null-as-omitted.
      buildTraceSummary: buildTraceSession.summary?.toJson(),
    );
    final updatedMetadata = await releaser.updatedReleaseMetadata(baseMetadata);
    await codePushClientWrapper.updateReleaseStatus(
      appId: appId,
      releaseId: release.id,
      platform: releaser.releaseType.releasePlatform,
      status: ReleaseStatus.active,
      selectionArches: release.selectionProtocol == 2
          ? (releaser.nativeSelectionArches.isEmpty
                ? [releaser.interpreterArchitecture.arch]
                : releaser.nativeSelectionArches)
          : null,
      metadata: updatedMetadata.toJson(),
    );
  }

  /// Instructions explaining how to patch the release that was just created.
  void printPatchInstructions({
    required Releaser releaser,
    required String releaseVersion,
    required ReleaseType releaseType,
    String? flavor,
    String? target,
  }) {
    final baseCommand = [
      'shorebird patch',
      '--platforms=${releaseType.cliName}',
      if (flavor != null) '--flavor=$flavor',
      if (target != null) '--target=$target',
    ].join(' ');
    logger.info(
      '''To create a patch for this release, run ${lightCyan.wrap('$baseCommand --release-version=$releaseVersion')}''',
    );
  }
}
