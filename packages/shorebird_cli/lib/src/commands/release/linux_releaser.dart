import 'dart:io';

import 'package:platform/platform.dart';
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/commands/build_preconditions.dart';
import 'package:shorebird_cli/src/commands/release/releaser.dart';
import 'package:shorebird_cli/src/doctor.dart';
import 'package:shorebird_cli/src/platform/desktop_architecture.dart';
import 'package:shorebird_cli/src/platform/platform.dart';
import 'package:shorebird_cli/src/release_type.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';

/// {@template linux_releaser}
/// Functions to create a linux release.
/// {@endtemplate}
class LinuxReleaser extends Releaser {
  /// {@macro linux_releaser}
  LinuxReleaser({
    required super.argResults,
    required super.flavor,
    required super.target,
  });

  @override
  FileSystemEntity get nativeSelectionPackage =>
      artifactManager.linuxBundleDirectory;
  @override
  List<String> get nativeSelectionArches => [
    DesktopArchitecture.native('linux').arch,
  ];

  @override
  ReleaseType get releaseType => ReleaseType.linux;

  @override
  String get supplementPlatformSubdir => 'linux';

  @override
  String get supplementArtifactArch => DesktopArchitecture.artifact(
    'linux_supplement',
    DesktopArchitecture.native('linux'),
  );

  @override
  String get artifactDisplayName => 'Linux app';

  @override
  Future<void> assertArgsAreValid() async {
    assertReleaseVersionFlagNotProvided();
    if (argResults.wasParsed('target-platform')) {
      throw ArtifactBuildException(
        '--target-platform is an Android release option. Desktop releases '
        'use the native Dart SDK architecture; cross compilation is '
        'unsupported.',
      );
    }
  }

  @override
  Future<void> assertPreconditions() => assertBuildPreconditions(
    validators: doctor.linuxCommandValidators,
    supportedOperatingSystems: {NativePlatform.linux},
  );

  @override
  Future<FileSystemEntity> buildReleaseArtifacts() async {
    await runReleaseBuild(
      (buildArgs, base64PublicKey) => artifactBuilder.buildLinuxApp(
        target: target,
        args: buildArgs,
        base64PublicKey: base64PublicKey,
      ),
    );

    return artifactManager.linuxBundleDirectory;
  }

  @override
  Future<String> getReleaseVersion({
    required FileSystemEntity releaseArtifactRoot,
  }) async => linux.versionFromLinuxBundle(
    bundleRoot: releaseArtifactRoot as Directory,
  );

  @override
  String get postReleaseInstructions =>
      '''

Linux release created at ${artifactManager.linuxBundleDirectory.path}.
''';

  @override
  Future<void> uploadReleaseArtifacts({
    required Release release,
    required String appId,
  }) async {
    await codePushClientWrapper.createLinuxReleaseArtifacts(
      appId: appId,
      releaseId: release.id,
      bundle: artifactManager.linuxBundleDirectory,
      signing: signing,
    );
  }
}
