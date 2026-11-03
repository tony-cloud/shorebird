import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:meta/meta.dart';
import 'package:open_aot_patch_tools/open_aot_patch_tools.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/commands/apple_build_helpers.dart';
import 'package:shorebird_cli/src/commands/release/apple_releaser_mixin.dart';
import 'package:shorebird_cli/src/commands/release/releaser.dart';
import 'package:shorebird_cli/src/common_arguments.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/doctor.dart';
import 'package:shorebird_cli/src/executables/ios_linker.dart';
import 'package:shorebird_cli/src/extensions/arg_results.dart';
import 'package:shorebird_cli/src/ios_aot_link.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform/apple/apple.dart';
import 'package:shorebird_cli/src/release_type.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:shorebird_cli/src/validators/validators.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';

/// {@template ios_releaser}
/// Functions to build and publish an iOS release.
/// {@endtemplate}
class IosReleaser extends Releaser with AppleReleaserMixin {
  /// {@macro ios_releaser}
  IosReleaser({
    required super.argResults,
    required super.flavor,
    required super.target,
  });

  @override
  ReleaseType get releaseType => ReleaseType.ios;

  @override
  String get supplementPlatformSubdir => 'ios';

  @override
  String get supplementArtifactArch => 'ios_supplement';

  @override
  String get artifactDisplayName => 'iOS app';

  @override
  List<Validator> get applePlatformValidators => doctor.iosCommandValidators;

  /// The kernel the `aot-link` release build produced.
  @visibleForTesting
  File? aotLinkKernel;

  /// Whether this release uses the iOS `aot-link` profile.
  bool get usesAotLink {
    try {
      return iosAotLinkSelected();
    } on AotLinkConfigurationException catch (error) {
      logger.err('$error');
      throw ProcessExit(ExitCode.usage.code);
    }
  }

  /// The `--aot-link-dd-max-bytes` threshold, or 0 (DD off, the default).
  int get aotLinkDdMaxBytes {
    final raw =
        argResults.options.contains(
          CommonArguments.aotLinkDdMaxBytesArg.name,
        )
        ? argResults[CommonArguments.aotLinkDdMaxBytesArg.name] as String?
        : null;
    if (raw == null) return 0;
    final value = int.tryParse(raw);
    if (value == null || value < 0) {
      logger.err(
        '--${CommonArguments.aotLinkDdMaxBytesArg.name} must be a '
        'non-negative integer (got $raw).',
      );
      throw ProcessExit(ExitCode.usage.code);
    }
    return value;
  }

  @override
  Future<void> assertArgsAreValid() async {
    assertReleaseVersionFlagNotProvided();
    argResults.assertValidExportOptionsPlistArg();
    if (!usesAotLink) return;
    if (useObfuscation) {
      logger.err(
        'The ios-aot-link profile does not support --obfuscate: link keys '
        'are recorded before obfuscation.',
      );
      throw ProcessExit(ExitCode.usage.code);
    }
    if (shorebirdEnv.getShorebirdYaml()?.selectionProtocol == 2) {
      logger.err(
        'The ios-aot-link profile does not support selection_protocol: 2 yet: '
        'the release scope has no aot-link runtime profile.',
      );
      throw ProcessExit(ExitCode.usage.code);
    }
    if (!argResults.patchSigningEnabled ||
        shorebirdEnv.getShorebirdYaml()?.patchVerification ==
            PatchVerification.installOnly) {
      logger.err(
        'ios-aot-link patches run downloaded code, so the release must verify '
        'them: remove --no-patch-signing and patch_verification: '
        'install_only.',
      );
      throw ProcessExit(ExitCode.usage.code);
    }
    if (iosLinker.toolPath == null) {
      logger.err(
        'The ios-aot-link profile needs the ios_linker tool: set '
        '$iosLinkerEnvVar to its .dart/.dill path or executable.',
      );
      throw ProcessExit(ExitCode.usage.code);
    }
  }

  @override
  Future<FileSystemEntity> buildReleaseArtifacts() async {
    if (!argResults.appleCodesign) {
      logger
        ..info(
          '''Building for device with codesigning disabled. You will have to manually codesign before deploying to device.''',
        )
        ..warn(
          '''shorebird preview will not work for releases created with "--no-codesign". However, you can still preview your app by signing the generated .xcarchive in Xcode.''',
        )
        ..warn(
          '''
When you distribute the .xcarchive in Xcode, you MUST uncheck "Manage Version and Build Number" in the Distribute App dialog.

If left checked, Xcode will rewrite the build number in the uploaded IPA, so the version that ships to App Store Connect will not match the version Shorebird recorded for this release. Patches will then fail to apply.''',
        );
    }

    final aotLink = usesAotLink;
    final aotLinkDd = aotLink ? aotLinkDdMaxBytes : 0;
    final build = await runReleaseBuild((buildArgs, base64PublicKey) async {
      // Other profiles leave the build environment alone.
      final previous = aotLink
          ? artifactBuilder.iosInterpreterBuildEnvironment
          : null;
      if (previous != null) {
        // The profile's own DD switch (off by default); the legacy
        // --dd-max-bytes default of 10000 does not apply.
        artifactBuilder.iosInterpreterBuildEnvironment = {
          ...previous,
          AotLinkEnvironment.tool: iosLinker.requireToolPath(),
          if (aotLinkDd > 0) ...{
            AotLinkEnvironment.ddMaxBytes: '$aotLinkDd',
            AotLinkEnvironment.ddPackages: appOwnPackages(projectRoot).join(
              ',',
            ),
          },
        };
      }
      try {
        return await artifactBuilder.buildIpa(
          codesign: argResults.appleCodesign,
          flavor: flavor,
          target: target,
          args: buildArgs,
          base64PublicKey: base64PublicKey,
          ddMaxBytes: aotLink ? null : ddMaxBytes,
        );
      } finally {
        if (previous != null) {
          artifactBuilder.iosInterpreterBuildEnvironment = previous;
        }
      }
    });
    if (aotLink) aotLinkKernel = build.kernelFile;

    final xcarchiveDirectory = artifactManager.getXcarchiveDirectory();
    if (xcarchiveDirectory == null) {
      logger.err('Unable to find .xcarchive directory');
      throw ProcessExit(ExitCode.software.code);
    }

    final appDirectory = artifactManager.getIosAppDirectory(
      xcarchiveDirectory: xcarchiveDirectory,
    );

    if (appDirectory == null) {
      logger.err('Unable to find .app directory');
      throw ProcessExit(ExitCode.software.code);
    }

    // Surface mismatched app extension versions here rather than letting the
    // user discover them via an App Store Connect rejection days later.
    // See https://github.com/tony-cloud/shorebird/issues/1956.
    final versionMismatches = findAppExtensionVersionMismatches(
      appDirectory: appDirectory,
    );
    if (versionMismatches.isNotEmpty) {
      logger.warn(appExtensionVersionMismatchWarning(versionMismatches));
    }

    // When code signing is requested (the default), `flutter build ipa` is
    // expected to export a signed .ipa. Flutter treats the export step as
    // optional and exits 0 even when it fails (e.g. no signing certificate),
    // so we must verify the .ipa was actually produced. Otherwise we would
    // report a successful release and point the user at an .ipa that does not
    // exist. See https://github.com/tony-cloud/shorebird/issues/3807.
    if (argResults.appleCodesign && artifactManager.getIpa() == null) {
      logger.err(
        '''
Unable to find generated IPA. This usually means that the IPA export step of "flutter build ipa" failed (for example, due to a missing or invalid code signing certificate). Review the build output above for the underlying error.

If you do not need a signed IPA (for example, you will sign the .xcarchive in Xcode), re-run this command with --no-codesign.''',
      );
      throw ProcessExit(ExitCode.software.code);
    }

    return xcarchiveDirectory;
  }

  @override
  Future<String> getReleaseVersion({
    required FileSystemEntity releaseArtifactRoot,
  }) async => readReleaseVersionFromInfoPlist(
    File(p.join(releaseArtifactRoot.path, 'Info.plist')),
  );

  @override
  Future<void> uploadReleaseArtifacts({
    required Release release,
    required String appId,
  }) async {
    final xcarchiveDirectory = artifactManager.getXcarchiveDirectory()!;
    await codePushClientWrapper.createIosReleaseArtifacts(
      appId: appId,
      releaseId: release.id,
      xcarchivePath: xcarchiveDirectory.path,
      runnerPath: artifactManager
          .getIosAppDirectory(xcarchiveDirectory: xcarchiveDirectory)!
          .path,
      isCodesigned: argResults.appleCodesign,
      podfileLockHash: shorebirdEnv.iosPodfileLockHash,
      signing: signing,
    );
  }

  /// Assembles the `aot-link` supplement in a fresh directory next to (never
  /// inside) the build outputs: the sidecar and optional DD targets
  /// flutter_tools wrote, the release kernel, the release `App.framework/App`
  /// as built (before App Store processing), and a manifest recording each
  /// file's SHA-256, the compiler identity and the release text hash.
  Future<Directory> assembleAotLinkSupplement() async {
    final built = Directory(
      p.join(projectRoot.path, 'build', supplementPlatformSubdir, 'shorebird'),
    );
    final link = File(p.join(built.path, AotLinkSupplement.linkFileName));
    final dd = File(p.join(built.path, AotLinkSupplement.ddFileName));
    final ddMaxBytes = aotLinkDdMaxBytes;
    final kernel = aotLinkKernel;
    final appDirectory = artifactManager.getIosAppDirectory(
      xcarchiveDirectory: artifactManager.getXcarchiveDirectory()!,
    );
    final binary = appDirectory == null
        ? null
        : File(p.join(appDirectory.path, 'Frameworks', 'App.framework', 'App'));
    final problems = [
      if (!link.existsSync())
        '${link.path} was not written (engine too old for ios-aot-link?)',
      if (ddMaxBytes > 0 && !dd.existsSync()) '${dd.path} was not written',
      if (ddMaxBytes == 0 && dd.existsSync()) '${dd.path} is stale',
      if (kernel == null || !kernel.existsSync())
        'the release kernel is missing',
      if (binary == null || !binary.existsSync())
        'the release App.framework/App is missing',
    ];
    if (problems.isNotEmpty) {
      logger.err(
        'Cannot create the ios-aot-link release supplement:\n'
        '${problems.map((e) => '  $e').join('\n')}',
      );
      throw ProcessExit(ExitCode.software.code);
    }

    final directory = Directory(
      p.join(projectRoot.path, 'build', supplementPlatformSubdir, 'aot_link'),
    );
    if (directory.existsSync()) directory.deleteSync(recursive: true);
    directory.createSync(recursive: true);
    link.copySync(p.join(directory.path, AotLinkSupplement.linkFileName));
    if (ddMaxBytes > 0) {
      dd.copySync(p.join(directory.path, AotLinkSupplement.ddFileName));
    }
    kernel!.copySync(p.join(directory.path, AotLinkSupplement.kernelFileName));
    final copiedBinary = binary!.copySync(
      p.join(directory.path, AotLinkSupplement.releaseBinaryFileName),
    );
    try {
      final info = await iosLinker.info(
        base: copiedBinary.path,
        baseLink: p.join(directory.path, AotLinkSupplement.linkFileName),
      );
      AotLinkSupplement.write(
        directory,
        releaseTextSha256: info.textSha256,
        textImageSize: info.textSize,
        ddMaxBytes: ddMaxBytes,
        ddPackages: ddMaxBytes > 0 ? appOwnPackages(projectRoot) : const [],
      );
    } on IosLinkerException catch (error) {
      logger.err('Cannot read the release App.framework/App: $error');
      throw ProcessExit(ExitCode.software.code);
    } on AotLinkSupplementException catch (error) {
      logger.err('$error');
      throw ProcessExit(ExitCode.software.code);
    }
    return directory;
  }

  @override
  Future<void> uploadSupplementArtifact({
    required String appId,
    required int releaseId,
    String? releaseVersion,
  }) async {
    if (!usesAotLink) {
      return super.uploadSupplementArtifact(
        appId: appId,
        releaseId: releaseId,
        releaseVersion: releaseVersion,
      );
    }
    final directory = await assembleAotLinkSupplement();
    AotLinkSupplement.stamp(
      directory,
      releaseId: releaseId,
      appBuildId: releaseVersion,
    );
    // The same signed supplement upload every other profile uses; the manifest
    // inside carries the SHA-256 of every file.
    await codePushClientWrapper.createSupplementReleaseArtifact(
      appId: appId,
      releaseId: releaseId,
      platform: releaseType.releasePlatform,
      supplementDirectoryPath: directory.path,
      arch: supplementArtifactArch,
      signing: signing,
    );
  }

  @override
  String get postReleaseInstructions {
    final relativeArchivePath = p.relative(
      artifactManager.getXcarchiveDirectory()!.path,
    );
    if (argResults.appleCodesign) {
      const ipaSearchString = 'build/ios/ipa/*.ipa';
      return '''

Your next step is to upload your app to App Store Connect.

To upload to the App Store, do one of the following:
    1. Open ${lightCyan.wrap(relativeArchivePath)} in Xcode and use the "Distribute App" flow.
    2. Drag and drop the ${lightCyan.wrap(ipaSearchString)} bundle into the Apple Transporter macOS app (https://apps.apple.com/us/app/transporter/id1450874784).
    3. Run ${lightCyan.wrap('xcrun altool --upload-app --type ios -f $ipaSearchString --apiKey your_api_key --apiIssuer your_issuer_id')}.
       See "man altool" for details about how to authenticate with the App Store Connect API key.
''';
    } else {
      return '''

Your next step is to submit the archive at ${lightCyan.wrap(relativeArchivePath)} to the App Store using Xcode.

You can open the archive in Xcode by running:
    ${lightCyan.wrap('open $relativeArchivePath')}

${styleBold.wrap('Make sure to uncheck "Manage Version and Build Number" in the Distribute App dialog.')}
If left checked, Xcode will rewrite the build number in the uploaded IPA, so the version that ships will not match the one Shorebird recorded for this release, and patches will fail to apply.
''';
    }
  }
}
