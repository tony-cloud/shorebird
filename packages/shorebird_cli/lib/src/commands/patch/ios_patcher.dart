import 'dart:async';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:open_aot_patch_tools/open_aot_patch_tools.dart' as open_patch;
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:shorebird_cli/src/archive/archive.dart';
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/commands/apple_build_helpers.dart';
import 'package:shorebird_cli/src/commands/patch/apple_patcher_mixin.dart';
import 'package:shorebird_cli/src/commands/patch/ios_interpreter_patcher_mixin.dart';
import 'package:shorebird_cli/src/commands/patch/patcher.dart';
import 'package:shorebird_cli/src/doctor.dart';
import 'package:shorebird_cli/src/extensions/arg_results.dart';
import 'package:shorebird_cli/src/extensions/directory.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform/platform.dart';
import 'package:shorebird_cli/src/release_type.dart';
import 'package:shorebird_cli/src/shorebird_artifacts.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:shorebird_cli/src/validators/validators.dart';

/// {@template ios_patcher}
/// Functions to create an iOS patch.
/// {@endtemplate}
class IosPatcher extends Patcher
    with
        ApplePatcherMixin,
        ApplePodfileLockPatcherMixin,
        AppleLinkerPatcherMixin,
        IosInterpreterPatcherMixin {
  /// {@macro ios_patcher}
  IosPatcher({
    required super.argResults,
    required super.argParser,
    required super.flavor,
    required super.target,
  });

  @override
  String? get interpreterPodfileLockHash => shorebirdEnv.iosPodfileLockHash;

  @override
  ReleaseType get releaseType => ReleaseType.ios;

  @override
  Version? get minimumFlutterVersion => minimumPatchableIosFlutterVersion;

  @override
  String get primaryReleaseArtifactArch => 'xcarchive';

  @override
  bool get requiresReleaseVersionArg =>
      iosPatchRuntimeMode == open_patch.runtimeModeDartBytecodeInterpreter;

  @override
  String? get supplementaryReleaseArtifactArch => 'ios_supplement';

  @override
  List<Validator> get applePlatformValidators => doctor.iosCommandValidators;

  @override
  String? get localPodfileLockHash => shorebirdEnv.iosPodfileLockHash;

  @override
  String get podfileLockRelativePath => 'ios/Podfile.lock';

  @override
  Future<void> assertArgsAreValid() async =>
      argResults.assertValidExportOptionsPlistArg();

  @override
  Future<File> buildPatchArtifact({String? releaseVersion}) async {
    final buildArgs = [
      ...argResults.forwardedArgs,
      ...extraBuildArgs,
      ...buildNameAndNumberArgsFromReleaseVersion(releaseVersion),
    ];

    // If buildIpa is called with a different codesign value than the
    // release was, we will erroneously report native diffs.
    final ipaBuildResult = await withInterpreterBaselineBuild(
      () async => artifactBuilder.buildIpa(
        codesign: argResults.appleCodesign,
        flavor: flavor,
        target: target,
        args: buildArgs,
        base64PublicKey: await getEncodedPublicKey(),
      ),
      buildArgs: buildArgs,
    );

    final runtimeMode = iosPatchRuntimeMode;
    if (runtimeMode == open_patch.runtimeModeNativeAot) {
      if (!allowsNativeIosAotPatch) {
        logger.err(
          'iOS native AOT patches require '
          'SHOREBIRD_IOS_NATIVE_AOT_PATCH=1.',
        );
        throw ProcessExit(ExitCode.software.code);
      }
      await buildAppleElfAotSnapshot(
        appDillPath: ipaBuildResult.kernelFile.path,
        outFilePath: aotOutputPath,
        genSnapshotArtifact: ShorebirdArtifact.genSnapshotIos,
      );
    } else if (runtimeMode == open_patch.runtimeModeDartBytecodeInterpreter) {
      await buildInterpreterBytecodePatch(buildArgs);
    } else {
      logger.err('Unsupported iOS patch runtime mode: $runtimeMode');
      throw ProcessExit(ExitCode.usage.code);
    }

    // Copy the kernel file to the build directory so that it can be used
    // to generate a patch.
    ipaBuildResult.kernelFile.copySync(appDillCopyPath);

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
    if (supplementDirectory != null) {
      releaseSupplementDirectory = supplementDirectory;
    }
    // Verify that we have built a patch .xcarchive
    if (artifactManager.getXcarchiveDirectory()?.path == null) {
      _noXcarchiveFound();
    }

    final runtimeMode = iosPatchRuntimeMode;
    if (runtimeMode == open_patch.runtimeModeDartBytecodeInterpreter) {
      return createInterpreterPatchArtifacts(
        appId: appId,
        releaseVersion: releaseVersion,
        releaseId: releaseId,
        releaseArtifact: releaseArtifact,
      );
    }
    if (runtimeMode != open_patch.runtimeModeNativeAot) {
      logger.err('Unsupported iOS patch runtime mode: $runtimeMode');
      throw ProcessExit(ExitCode.usage.code);
    }
    if (!allowsNativeIosAotPatch) {
      logger.err(
        '''
iOS native AOT patch artifacts are disabled by default because they require mapping downloaded native snapshot text as executable memory.
Use the open interpreter route (`aot_patch_runtime_mode: dart-bytecode-interpreter`) for App Store-safe patches.
Set SHOREBIRD_IOS_NATIVE_AOT_PATCH=1 only for development-device validation.''',
      );
      throw ProcessExit(ExitCode.software.code);
    }

    final unzipProgress = logger.progress('Extracting release artifact');

    final releaseXcarchiveDirectory = Directory.systemTemp.createTempSync();
    // Only a supplement directory created here is ours to delete; one passed
    // in belongs to the caller.
    final fallbackSupplementDirectory = supplementDirectory == null
        ? Directory.systemTemp.createTempSync()
        : null;
    try {
      await artifactManager.extractZip(
        zipFile: releaseArtifact,
        outputDirectory: releaseXcarchiveDirectory,
      );

      unzipProgress.complete();
      final appDirectory = artifactManager.getIosAppDirectory(
        xcarchiveDirectory: releaseXcarchiveDirectory,
      );
      if (appDirectory == null) {
        logger
          ..err(
            'The release .xcarchive downloaded from Shorebird has no '
            'Products/Applications/*.app directory.',
          )
          ..info(
            'Re-run to download it again. If this persists, the release '
            'artifact is damaged; create a new release with '
            '${lightCyan.wrap('shorebird release ios')} and patch that one.',
          );
        throw ProcessExit(ExitCode.software.code);
      }
      final releaseArtifactFile = File(
        p.join(appDirectory.path, 'Frameworks', 'App.framework', 'App'),
      );

      // The returned bundles point at the diff or the patch build output,
      // never into the extracted release, so it can go once this returns.
      return await linkAndBundlePatch(
        releaseArtifactFile: releaseArtifactFile,
        releaseSupplementDir:
            supplementDirectory ?? fallbackSupplementDirectory!,
        podfileLockHash: shorebirdEnv.iosPodfileLockHash,
      );
    } finally {
      releaseXcarchiveDirectory.deleteTemporarySync();
      if (fallbackSupplementDirectory != null) {
        fallbackSupplementDirectory.deleteTemporarySync();
      }
    }
  }

  @override
  Future<String> extractReleaseVersionFromArtifact(File artifact) async {
    final archivePath = artifactManager.getXcarchiveDirectory()?.path;
    if (archivePath == null) _noXcarchiveFound();

    return readReleaseVersionFromInfoPlist(
      File(p.join(archivePath, 'Info.plist')),
      hint: passReleaseVersionHint,
    );
  }

  /// Logs that `flutter build ipa` left no .xcarchive where Shorebird looks
  /// for it and throws [ProcessExit].
  Never _noXcarchiveFound() {
    final archiveDirectory = p.join(
      shorebirdEnv.getShorebirdProjectRoot()!.path,
      'build',
      'ios',
      'archive',
    );
    logger
      ..err('No .xcarchive found in $archiveDirectory after the build.')
      ..info(
        'Shorebird looks for the archive that '
        '${lightCyan.wrap('flutter build ipa')} writes there. '
        'Re-run with --verbose to see the build output.',
      );
    throw ProcessExit(ExitCode.software.code);
  }
}
