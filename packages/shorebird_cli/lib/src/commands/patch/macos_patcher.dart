import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/commands/apple_build_helpers.dart';
import 'package:shorebird_cli/src/commands/patch/apple_patcher_mixin.dart';
import 'package:shorebird_cli/src/commands/patch/patch.dart';
import 'package:shorebird_cli/src/doctor.dart';
import 'package:shorebird_cli/src/executables/executables.dart';
import 'package:shorebird_cli/src/extensions/arg_results.dart';
import 'package:shorebird_cli/src/extensions/directory.dart';
import 'package:shorebird_cli/src/logging/shorebird_logger.dart';
import 'package:shorebird_cli/src/platform/platform.dart';
import 'package:shorebird_cli/src/release_type.dart';
import 'package:shorebird_cli/src/shorebird_artifacts.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:shorebird_cli/src/validators/validators.dart';

/// {@template macos_patcher}
/// Functions to create and apply patches to a macOS release.
///
/// macOS is a desktop platform but deliberately not a [DesktopPatcher]: its
/// patches are built the Apple way and share their code with iOS through
/// [ApplePatcherMixin] instead. Unlike Linux and Windows, a macOS patch:
///
/// - covers two architectures (arm64 and x86_64), each with its own AOT
///   snapshot built by `gen_snapshot`, rather than one x86_64 library taken
///   from the `flutter build` output;
/// - uses the complete release App.framework/App as the diff base, matching
///   this open engine's whole-file updater contract;
/// - archives the app with `ditto` rather than `zip`, and checks the
///   Podfile.lock hash and codesigning.
/// {@endtemplate}
class MacosPatcher extends Patcher
    with ApplePatcherMixin, ApplePodfileLockPatcherMixin {
  /// {@macro macos_patcher}
  MacosPatcher({
    required super.argParser,
    required super.argResults,
    required super.flavor,
    required super.target,
  });

  // The elf snapshot built for Apple Silicon macs.
  String get _arm64AotOutputPath =>
      p.join(shorebirdEnv.buildDirectory.path, 'out.arm64.aot');

  // The elf snapshot built for Intel macs.
  String get _x64AotOutputPath =>
      p.join(shorebirdEnv.buildDirectory.path, 'out.x64.aot');

  @override
  ReleaseType get releaseType => ReleaseType.macos;

  @override
  Version? get minimumFlutterVersion => minimumSupportedMacosFlutterVersion;

  @override
  String get primaryReleaseArtifactArch => 'app';

  @override
  String? get supplementaryReleaseArtifactArch => 'macos_supplement';

  @override
  List<Validator> get applePlatformValidators => doctor.macosCommandValidators;

  @override
  String? get localPodfileLockHash => shorebirdEnv.macosPodfileLockHash;

  @override
  String get podfileLockRelativePath => 'macos/Podfile.lock';

  @override
  Future<File> buildPatchArtifact({String? releaseVersion}) async {
    final buildArgs = [
      ...argResults.forwardedArgs,
      ...extraBuildArgs,
      ...buildNameAndNumberArgsFromReleaseVersion(releaseVersion),
    ];

    // If buildMacos is called with a different codesign value than the
    // release was, we will erroneously report native diffs.
    final macosBuildResult = await artifactBuilder.buildMacos(
      codesign: argResults.appleCodesign,
      flavor: flavor,
      target: target,
      args: buildArgs,
      base64PublicKey: await getEncodedPublicKey(),
    );

    await buildAppleElfAotSnapshot(
      appDillPath: macosBuildResult.kernelFile.path,
      outFilePath: _arm64AotOutputPath,
      genSnapshotArtifact: ShorebirdArtifact.genSnapshotMacosArm64,
    );

    if (!File(_arm64AotOutputPath).existsSync()) {
      throw Exception('Failed to build arm64 AOT snapshot');
    }

    await buildAppleElfAotSnapshot(
      appDillPath: macosBuildResult.kernelFile.path,
      outFilePath: _x64AotOutputPath,
      genSnapshotArtifact: ShorebirdArtifact.genSnapshotMacosX64,
    );

    if (!File(_x64AotOutputPath).existsSync()) {
      throw Exception('Failed to build x64 AOT snapshot');
    }

    // Copy the kernel file to the build directory so that it can be used
    // to generate a patch.
    macosBuildResult.kernelFile.copySync(appDillCopyPath);

    final appPath = artifactManager.getMacOSAppDirectory(flavor: flavor)!.path;
    final tempDir = await Directory.systemTemp.createTemp();
    final zippedApp = File(p.join(tempDir.path, '${p.basename(appPath)}.zip'));
    await ditto.archive(
      source: appPath,
      destination: zippedApp.path,
      // keepParent is false here in order to ensure the directory structure of
      // this zip file matches what will be provided to the [AppleArchiveDiffer]
      // (which uses package:archive to stream zip file contents).
    );
    return zippedApp;
  }

  @override
  Future<Map<Arch, PatchArtifactBundle>> createPatchArtifacts({
    required String appId,
    required int releaseId,
    required File releaseArtifact,
    Directory? supplementDirectory,
    String? releaseVersion,
  }) async {
    final unzipProgress = logger.progress('Extracting release artifact');
    // The extracted release is only needed while creating the diffs, which
    // are written elsewhere, so it is deleted afterwards.
    final releaseAppDirectory = Directory.systemTemp.createTempSync();
    try {
      await ditto.extract(
        source: releaseArtifact.path,
        destination: releaseAppDirectory.path,
      );
      unzipProgress.complete();

      final releaseArtifactFile = File(
        p.join(
          releaseAppDirectory.path,
          'Contents',
          'Frameworks',
          'App.framework',
          'App',
        ),
      );

      final createDiffProgress = logger.progress('Creating patch artifacts');
      final arm64Bundle = await createDiffBundle(
        arch: Arch.arm64,
        releaseArtifactPath: releaseArtifactFile.path,
        patchArtifactPath: _arm64AotOutputPath,
        progress: createDiffProgress,
        podfileLockHash: shorebirdEnv.macosPodfileLockHash,
      );
      final x64Bundle = await createDiffBundle(
        arch: Arch.x86_64,
        releaseArtifactPath: releaseArtifactFile.path,
        patchArtifactPath: _x64AotOutputPath,
        progress: createDiffProgress,
        podfileLockHash: shorebirdEnv.macosPodfileLockHash,
      );
      createDiffProgress.complete();

      return {Arch.x86_64: x64Bundle, Arch.arm64: arm64Bundle};
    } finally {
      releaseAppDirectory.deleteTemporarySync();
    }
  }

  @override
  Future<String> extractReleaseVersionFromArtifact(File artifact) async {
    final appPath = artifactManager.getMacOSAppDirectory(flavor: flavor)?.path;
    if (appPath == null) {
      logger.err('Unable to find .app directory');
      throw ProcessExit(ExitCode.software.code);
    }

    return readReleaseVersionFromInfoPlist(
      File(p.join(appPath, 'Contents', 'Info.plist')),
      hint: passReleaseVersionHint,
    );
  }
}
