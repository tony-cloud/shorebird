import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:open_aot_patch_tools/open_aot_patch_tools.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/commands/patch/apple_patcher_mixin.dart';
import 'package:shorebird_cli/src/commands/patch/patcher.dart';
import 'package:shorebird_cli/src/common_arguments.dart';
import 'package:shorebird_cli/src/executables/ios_linker.dart';
import 'package:shorebird_cli/src/ios_aot_link.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform/platform.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';

/// The iOS `aot-link` patch route.
///
/// The release supplement (see `IosReleaser.assembleAotLinkSupplement`)
/// carries the release sidecar, DD targets, kernel and the release
/// `App.framework/App`. A patch is built by flutter_tools against that
/// sidecar (`--link_base`, then pool hints, then the final ELF), `ios_linker
/// link` maps unchanged code onto the release's native instructions, `check`
/// verifies the result independently, and `diff-base` plus the updater's
/// bidiff+zstd transport make the download. The patch's hash is signed exactly
/// like every other patch; nothing about signing is special-cased here.
mixin IosAotLinkPatcherMixin
    on Patcher, ApplePatcherMixin, AppleLinkerPatcherMixin {
  /// Where flutter_tools leaves the patch ELF and its sidecar, outside the
  /// app bundle.
  Directory get aotLinkBuildDirectory => shorebirdEnv.iosSupplementDirectory;

  /// The vmcode written by the linker.
  String get aotLinkVmcodePath =>
      p.join(shorebirdEnv.buildDirectory.path, 'out.vmcode');

  /// The link report written by the linker.
  String get aotLinkReportPath =>
      p.join(shorebirdEnv.buildDirectory.path, 'out.link_report.json');

  /// The release data+text blob the download is diffed against.
  String get aotLinkDiffBasePath =>
      p.join(shorebirdEnv.buildDirectory.path, 'App.diffbase');

  /// Whether this patch uses the `aot-link` profile.
  bool get aotLinkSelected {
    try {
      return iosAotLinkSelected();
    } on AotLinkConfigurationException catch (error) {
      logger.err('$error');
      throw ProcessExit(ExitCode.usage.code);
    }
  }

  /// Warn and fail thresholds. `--min-link-percentage` fails the patch only
  /// when given explicitly; otherwise upstream's 20% applies.
  AotLinkPolicy get aotLinkPolicy {
    num percent(String name, num fallback) {
      if (!argResults.options.contains(name)) return fallback;
      final raw = argResults[name] as String?;
      if (raw == null) return fallback;
      final value = num.tryParse(raw);
      if (value == null || value < 0 || value > 100) {
        logger.err('--$name must be a number between 0 and 100 (got $raw).');
        throw ProcessExit(ExitCode.usage.code);
      }
      return value;
    }

    final failBelow =
        argResults.options.contains(CommonArguments.minLinkPercentage.name) &&
            argResults.wasParsed(CommonArguments.minLinkPercentage.name)
        ? percent(
            CommonArguments.minLinkPercentage.name,
            AotLinkPolicy.defaultFailBelow,
          )
        : AotLinkPolicy.defaultFailBelow;
    final warnBelow = percent(
      CommonArguments.warnLinkPercentage.name,
      AotLinkPolicy.defaultWarnBelow,
    );
    if (failBelow > warnBelow) {
      logger.err(
        '--${CommonArguments.minLinkPercentage.name} ($failBelow) must not '
        'exceed --${CommonArguments.warnLinkPercentage.name} ($warnBelow).',
      );
      throw ProcessExit(ExitCode.usage.code);
    }
    return AotLinkPolicy(warnBelow: warnBelow, failBelow: failBelow);
  }

  /// Verifies the downloaded supplement against its manifest. Throws
  /// [ProcessExit] with a clear message when it cannot be used.
  AotLinkSupplement verifyAotLinkSupplement() {
    final directory = releaseSupplementDirectory;
    if (directory == null) {
      logger.err(
        'This release has no supplement. Create the release with the '
        'ios-aot-link profile (aot_patch_runtime_mode: ios-aot-link) before '
        'patching it.',
      );
      throw ProcessExit(ExitCode.software.code);
    }
    try {
      return AotLinkSupplement.verify(directory);
    } on AotLinkSupplementException catch (error) {
      logger.err('$error');
      throw ProcessExit(ExitCode.software.code);
    }
  }

  String _supplementFile(String name) =>
      p.join(releaseSupplementDirectory!.path, name);

  /// Runs [build] (the flutter build of the patch) with the environment that
  /// makes flutter_tools compile against the release.
  Future<T> withAotLinkBuild<T>(Future<T> Function() build) async {
    final supplement = verifyAotLinkSupplement();
    if (iosLinker.toolPath == null) {
      logger.err(
        'The ios-aot-link profile needs the ios_linker tool: set '
        '$iosLinkerEnvVar to its .dart/.dill path or executable.',
      );
      throw ProcessExit(ExitCode.usage.code);
    }
    if (obfuscate) {
      logger.err('The ios-aot-link profile does not support --obfuscate.');
      throw ProcessExit(ExitCode.usage.code);
    }
    // The supplement is only as trustworthy as its binary: recompute the text
    // hash from the stored release binary rather than believing the manifest.
    try {
      final info = await iosLinker.info(
        base: _supplementFile(AotLinkSupplement.releaseBinaryFileName),
        baseLink: _supplementFile(AotLinkSupplement.linkFileName),
      );
      if (info.textSha256 != supplement.releaseTextSha256 ||
          info.textSize != supplement.textImageSize) {
        logger.err(
          'The release App.framework/App in the supplement does not hash to '
          'the recorded release text '
          '(${info.textSha256} != ${supplement.releaseTextSha256}).',
        );
        throw ProcessExit(ExitCode.software.code);
      }
    } on IosLinkerException catch (error) {
      logger.err('Cannot read the release binary: $error');
      throw ProcessExit(ExitCode.software.code);
    }

    final previous = artifactBuilder.iosInterpreterBuildEnvironment;
    artifactBuilder.iosInterpreterBuildEnvironment = {
      ...previous,
      AotLinkEnvironment.tool: iosLinker.requireToolPath(),
      AotLinkEnvironment.base: p.absolute(
        _supplementFile(AotLinkSupplement.linkFileName),
      ),
      if (supplement.usesDd)
        AotLinkEnvironment.ddTargets: p.absolute(
          _supplementFile(AotLinkSupplement.ddFileName),
        ),
    };
    try {
      return await build();
    } finally {
      artifactBuilder.iosInterpreterBuildEnvironment = previous;
    }
  }

  /// Links, verifies and packages the patch built by [withAotLinkBuild].
  Future<Map<Arch, PatchArtifactBundle>> createAotLinkPatchArtifacts({
    String? podfileLockHash,
  }) async {
    final supplement = verifyAotLinkSupplement();
    final policy = aotLinkPolicy;
    final patchElf = File(p.join(aotLinkBuildDirectory.path, 'out.aot'));
    final patchLink = File(p.join(aotLinkBuildDirectory.path, 'out.link'));
    for (final file in [patchElf, patchLink]) {
      if (!file.existsSync()) {
        logger.err(
          'The patch build did not produce ${file.path}. The Flutter engine '
          'must support the ios-aot-link profile (gen_snapshot '
          '--print_link_info_to/--link_base).',
        );
        throw ProcessExit(ExitCode.software.code);
      }
    }
    final base = _supplementFile(AotLinkSupplement.releaseBinaryFileName);
    final baseLink = _supplementFile(AotLinkSupplement.linkFileName);
    final vmcode = File(aotLinkVmcodePath);
    if (vmcode.existsSync()) vmcode.deleteSync();

    Never fail(IosLinkerException error) {
      logger.err(error.message);
      throw ProcessExit(ExitCode.software.code);
    }

    final linkProgress = logger.progress('Linking the patch to the release');
    final IosLinkReport report;
    try {
      report = await iosLinker.link(
        base: base,
        baseLink: baseLink,
        patchElf: patchElf.path,
        patchLink: patchLink.path,
        outVmcode: vmcode.path,
        reportPath: aotLinkReportPath,
        minLinkPercent: policy.failBelow,
      );
      linkProgress.complete(
        "Linked ${report.linkPercent.toStringAsFixed(1)}% of the patch's "
        'code to the release',
      );
    } on IosLinkerException catch (error) {
      linkProgress.fail();
      fail(error);
    }

    final checkProgress = logger.progress('Verifying the linked patch');
    try {
      await iosLinker.check(
        vmcode: vmcode.path,
        base: base,
        patchElf: patchElf.path,
        baseLink: baseLink,
        patchLink: patchLink.path,
        minLinkPercent: policy.failBelow,
      );
      checkProgress.complete();
    } on IosLinkerException catch (error) {
      checkProgress.fail();
      fail(error);
    }

    // The vmcode must name exactly the release the supplement recorded.
    try {
      final header = VmcodeHeader.readVerified(vmcode);
      if (header.releaseTextSha256 != supplement.releaseTextSha256 ||
          header.releaseTextSize != supplement.textImageSize) {
        logger.err(
          'The linked patch names a different release text '
          '(${header.releaseTextSha256}) than the release supplement '
          '(${supplement.releaseTextSha256}).',
        );
        throw ProcessExit(ExitCode.software.code);
      }
    } on FormatException catch (error) {
      logger.err('The linker wrote an invalid vmcode: ${error.message}');
      throw ProcessExit(ExitCode.software.code);
    }

    if (report.linkPercent < policy.warnBelow) {
      logger.warn(
        '''
Only ${report.linkPercent.toStringAsFixed(1)}% of this patch's code can reuse the release's native code (warning threshold ${policy.warnBelow}%).
The rest runs in the simulator and may be much slower. ${report.unlinkedEntries} functions are affected; see $aotLinkReportPath for the largest.''',
      );
    }
    recordLinkResult(
      percentage: report.linkPercent,
      metadata: {
        'link_percent': report.linkPercent,
        'patch_code_bytes': report.patchCodeBytes,
        'linked_code_bytes': report.linkedCodeBytes,
        'unlinked_entries': report.unlinkedEntries,
        'unlinked_by_reason': report.json['unlinked_by_reason'],
        'profile': profileAotLink,
      },
    );

    final diffBase = File(aotLinkDiffBasePath);
    final diffProgress = logger.progress('Creating the patch download');
    try {
      await iosLinker.diffBase(
        base: base,
        baseLink: baseLink,
        out: diffBase.path,
      );
    } on IosLinkerException catch (error) {
      diffProgress.fail();
      fail(error);
    }
    // The hash and signature are of the whole vmcode, which is what the
    // updater has after applying the download to the installed release.
    final bundle = await createDiffBundle(
      arch: Arch.arm64,
      releaseArtifactPath: diffBase.path,
      patchArtifactPath: vmcode.path,
      progress: diffProgress,
      podfileLockHash: podfileLockHash,
    );
    diffProgress.complete();
    if (bundle.hashSignature == null) {
      logger.warn(
        'This patch is not signed. A release built with patch signing '
        '(the default) will refuse it.',
      );
    }
    return {Arch.arm64: bundle};
  }
}
