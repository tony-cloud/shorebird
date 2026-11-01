import 'package:mason_logger/mason_logger.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/commands/app_scoped_command.dart';
import 'package:shorebird_cli/src/commands/release/native_selection_publication.dart';
import 'package:shorebird_cli/src/json_output.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';

/// Activates an explicitly complete set of staged native architecture packages.
class ReleaseFinalizeCommand extends ShorebirdCommand with AppScopedCommand {
  /// Creates the explicit architecture-set finalization command.
  ReleaseFinalizeCommand() {
    addAppScopeOptions();
    argParser
      ..addOption(
        'platform',
        mandatory: true,
        allowed: ['android', 'linux', 'windows'],
      )
      ..addOption('release-version', mandatory: true)
      ..addMultiOption(
        'arch',
        help: 'Exact complete wire architecture set (comma separated).',
      );
  }
  @override
  String get name => 'release-finalize';
  @override
  String get description =>
      'Verify and activate staged native protocol-2 release packages.';
  @override
  Future<int> run() async {
    final (:appId, :errorCode) = await resolveAppId();
    if (errorCode != null) return errorCode;
    final arches = results['arch'] as List<String>;
    if (arches.isEmpty) {
      usageException(
        '--arch must explicitly name the complete architecture set.',
      );
    }
    final platform = ReleasePlatform.values.singleWhere(
      (p) => p.name == results['platform'],
    );
    final release = await codePushClientWrapper.getRelease(
      appId: appId,
      releaseVersion: results['release-version'] as String,
    );
    if (release.selectionProtocol != 2 ||
        release.platforms[platform]?.status != ReleaseStatus.draft) {
      usageException('Only a draft protocol-2 platform can be finalized.');
    }
    await NativeSelectionPublication.verify(
      appId: appId,
      release: release,
      platform: platform,
      arches: arches,
      expectedNativePatchMaxBytes: shorebirdEnv
          .getShorebirdYaml()
          ?.nativePatchMaxBytes,
    );
    await codePushClientWrapper.updateReleaseStatus(
      appId: appId,
      releaseId: release.id,
      platform: platform,
      status: ReleaseStatus.active,
      selectionArches: arches,
    );
    if (isJsonMode) {
      emitJsonSuccess({
        'release_version': release.version,
        'platform': platform.name,
        'selection_arches': arches,
      });
    } else {
      logger.success(
        'Published Release ${release.version} '
        '(${platform.name}: ${arches.join(', ')})',
      );
    }
    return ExitCode.success.code;
  }
}
