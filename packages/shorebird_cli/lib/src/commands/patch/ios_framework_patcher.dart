import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:open_aot_patch_tools/open_aot_patch_tools.dart' as open_patch;
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:shorebird_cli/src/archive/directory_archive.dart';
import 'package:shorebird_cli/src/archive_analysis/apple_archive_differ.dart';
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/commands/patch/apple_patcher_mixin.dart';
import 'package:shorebird_cli/src/commands/patch/ios_interpreter_patcher_mixin.dart';
import 'package:shorebird_cli/src/commands/patch/patch.dart';
import 'package:shorebird_cli/src/doctor.dart';
import 'package:shorebird_cli/src/extensions/arg_results.dart';
import 'package:shorebird_cli/src/extensions/directory.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/patch_diff_checker.dart';
import 'package:shorebird_cli/src/platform/platform.dart';
import 'package:shorebird_cli/src/release_type.dart';
import 'package:shorebird_cli/src/shorebird_artifacts.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:shorebird_cli/src/validators/validators.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';

/// {@template ios_framework_patcher}
/// Functions to patch an iOS Framework release.
/// {@endtemplate}
class IosFrameworkPatcher extends Patcher
    with
        ApplePatcherMixin,
        AppleLinkerPatcherMixin,
        IosInterpreterPatcherMixin {
  /// {@macro ios_framework_patcher}
  IosFrameworkPatcher({
    required super.argResults,
    required super.argParser,
    required super.flavor,
    required super.target,
  });

  @override
  String get primaryReleaseArtifactArch => 'xcframework';

  @override
  String? get supplementaryReleaseArtifactArch => 'ios_framework_supplement';

  @override
  ReleaseType get releaseType => ReleaseType.iosFramework;

  @override
  Version? get minimumFlutterVersion => minimumPatchableIosFlutterVersion;

  @override
  List<Validator> get applePlatformValidators => doctor.iosCommandValidators;

  @override
  bool get requiresReleaseVersionArg => true;

  @override
  Future<DiffStatus> assertUnpatchableDiffs({
    required ReleaseArtifact releaseArtifact,
    required File releaseArchive,
    required File patchArchive,
  }) => patchDiffChecker.confirmUnpatchableDiffsIfNecessary(
    localArchive: patchArchive,
    releaseArchive: releaseArchive,
    archiveDiffer: archiveDifferOverride ?? const AppleArchiveDiffer(),
    allowAssetChanges: allowAssetDiffs,
    allowNativeChanges: allowNativeDiffs,
  );

  @override
  Future<File> buildPatchArtifact({String? releaseVersion}) async {
    final buildArgs = [
      ...argResults.forwardedArgs,
      ...extraBuildArgs,
      // `patch` parses `--no-codesign` itself (for ipa builds), so it isn't
      // forwarded with the rest.
      if (!argResults.appleCodesign) '--no-codesign',
    ];
    final buildResult = await withInterpreterBaselineBuild(
      () async => artifactBuilder.buildIosFramework(
        target: target,
        args: buildArgs,
        base64PublicKey: await getEncodedPublicKey(),
      ),
      buildArgs: buildArgs,
    );

    final runtimeMode = iosPatchRuntimeMode;
    if (runtimeMode == open_patch.runtimeModeDartBytecodeInterpreter) {
      await buildInterpreterBytecodePatch(buildArgs);
    } else if (runtimeMode == open_patch.runtimeModeNativeAot &&
        allowsNativeIosAotPatch) {
      await buildAppleElfAotSnapshot(
        appDillPath: buildResult.kernelFile.path,
        outFilePath: aotOutputPath,
        genSnapshotArtifact: ShorebirdArtifact.genSnapshotIos,
      );
    } else {
      _unsupportedRuntimeMode();
    }

    // Copy the kernel file to the build directory so that it can be used
    // to generate a patch.
    buildResult.kernelFile.copySync(appDillCopyPath);

    return Directory(
      p.join(
        artifactManager.getAppXcframeworkDirectory().path,
        ArtifactManager.appXcframeworkName,
      ),
    ).zipToTempFile();
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
    if (iosPatchRuntimeMode == open_patch.runtimeModeDartBytecodeInterpreter) {
      return createInterpreterPatchArtifacts(
        appId: appId,
        releaseVersion: releaseVersion,
        releaseId: releaseId,
        releaseArtifact: releaseArtifact,
      );
    }
    if (iosPatchRuntimeMode != open_patch.runtimeModeNativeAot ||
        !allowsNativeIosAotPatch) {
      _unsupportedRuntimeMode();
    }

    final unzipProgress = logger.progress('Extracting release artifact');
    final releaseXcframeworkDirectory = Directory.systemTemp.createTempSync();
    // Only a supplement directory created here is ours to delete; one passed
    // in belongs to the caller.
    final fallbackSupplementDirectory = supplementDirectory == null
        ? Directory.systemTemp.createTempSync()
        : null;
    try {
      await artifactManager.extractZip(
        zipFile: releaseArtifact,
        outputDirectory: releaseXcframeworkDirectory,
      );

      unzipProgress.complete();
      final releaseArtifactFile = File(
        p.join(
          releaseXcframeworkDirectory.path,
          'ios-arm64',
          'App.framework',
          'App',
        ),
      );

      // The returned bundles point at the diff or the patch build output,
      // never into the extracted release, so it can go once this returns.
      return await linkAndBundlePatch(
        releaseArtifactFile: releaseArtifactFile,
        releaseSupplementDir:
            supplementDirectory ?? fallbackSupplementDirectory!,
      );
    } finally {
      releaseXcframeworkDirectory.deleteTemporarySync();
      if (fallbackSupplementDirectory != null) {
        fallbackSupplementDirectory.deleteTemporarySync();
      }
    }
  }

  Never _unsupportedRuntimeMode() {
    logger.err(
      'Unsupported iOS framework patch runtime mode: $iosPatchRuntimeMode. '
      'Use dart-bytecode-interpreter; native-aot requires explicit '
      'SHOREBIRD_IOS_NATIVE_AOT_PATCH=1 development opt-in.',
    );
    throw ProcessExit(ExitCode.usage.code);
  }

  @override
  Future<String> extractReleaseVersionFromArtifact(File artifact) {
    // Not implemented - release version must be specified by the user.
    throw UnimplementedError(
      'Release version must be specified using --release-version.',
    );
  }
}
