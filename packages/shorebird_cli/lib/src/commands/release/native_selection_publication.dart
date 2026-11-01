import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:shorebird_cli/src/archive_analysis/native_selection_archive.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/code_signer.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';

/// Re-downloads stored native packages before attesting their immutable scopes.
class NativeSelectionPublication {
  /// Verifies complete requested packages and optionally creates registrations.
  /// Finalization uses existing registrations only, and requires the exact set.
  static Future<void> verify({
    required String appId,
    required Release release,
    required ReleasePlatform platform,
    required List<String> arches,
    required int? expectedNativePatchMaxBytes,
    int? expectedSigningKeyId,
    bool register = false,
  }) async {
    final client = codePushClientWrapper.codePushClient;
    final artifacts = await client.getReleaseArtifacts(
      appId: appId,
      releaseId: release.id,
      platform: platform,
    );
    final registrations = await client.getReleaseSelectionScopes(
      appId: appId,
      releaseId: release.id,
    );
    final requested = arches.toSet();
    if (arches.isEmpty ||
        requested.length != arches.length ||
        !const {'arm', 'aarch64', 'x86_64'}.containsAll(requested) ||
        (platform != ReleasePlatform.android && requested.contains('arm'))) {
      throw const FormatException('Invalid expected native architecture set');
    }
    if (!register && platform != ReleasePlatform.android) {
      final primaryPrefix = platform == ReleasePlatform.linux
          ? 'bundle'
          : 'win_archive';
      final staged = artifacts
          .where(
            (a) =>
                a.arch == primaryPrefix || a.arch == '${primaryPrefix}_aarch64',
          )
          .map((a) => a.arch == primaryPrefix ? 'x86_64' : 'aarch64')
          .toSet();
      if (staged.length != requested.length || !staged.containsAll(requested)) {
        throw const FormatException(
          'Staged package architecture set differs from --arch',
        );
      }
    }
    if (!register) {
      final existing = registrations
          .where(
            (r) =>
                (r['scope'] as Map<String, dynamic>)['platform'] ==
                platform.name,
          )
          .map((r) => (r['scope'] as Map<String, dynamic>)['arch'])
          .toSet();
      if (existing.length != requested.length ||
          !existing.containsAll(requested)) {
        throw const FormatException(
          'Staged registration architecture set differs from --arch',
        );
      }
    }
    final temp = Directory.systemTemp.createTempSync(
      'shorebird-native-publication-',
    );
    final downloaded = <int, File>{};
    final pending =
        <({ReleaseSelectionScope scope, int primary, int? supplement})>[];
    try {
      Future<File> retrieve(ReleaseArtifact artifact) async {
        if (downloaded[artifact.id] case final file?) {
          return file;
        }
        final file = await artifactManager.downloadFile(
          Uri.parse(artifact.url),
          outputPath: '${temp.path}/${artifact.id}',
        );
        if (file.lengthSync() != artifact.size ||
            sha256.convert(file.readAsBytesSync()).toString() !=
                artifact.hash) {
          throw const FormatException(
            'Stored native artifact hash/size mismatch',
          );
        }
        return downloaded[artifact.id] = file;
      }

      var keyId = expectedSigningKeyId;
      String? publicKey;
      for (final arch in arches) {
        final primaryArch = switch (platform) {
          ReleasePlatform.android => 'aab',
          ReleasePlatform.linux =>
            arch == 'aarch64' ? 'bundle_aarch64' : 'bundle',
          ReleasePlatform.windows =>
            arch == 'aarch64' ? 'win_archive_aarch64' : 'win_archive',
          _ => throw const FormatException(
            'Unsupported native publication platform',
          ),
        };
        final primary = artifacts.singleWhere((a) => a.arch == primaryArch);
        final signing = primary.signing;
        if (signing?.mode != 'managed' ||
            signing?.keyId == null ||
            signing?.publicKeyPem == null ||
            (keyId != null && keyId != signing!.keyId) ||
            (publicKey != null && publicKey != signing!.publicKeyPem)) {
          throw const FormatException(
            'Inconsistent managed native release signing key',
          );
        }
        keyId = signing!.keyId;
        publicKey = signing.publicKeyPem;
        final file = await retrieve(primary);
        final packageArches = platform == ReleasePlatform.android
            ? arches
            : [arch];
        final scopes = NativeSelectionArchive.verify(
          file,
          appId: appId,
          version: release.version,
          platform: platform.name,
          arches: packageArches,
          expectedPublicKey: codeSigner.base64PublicKeyFromPem(publicKey!),
          expectedNativePatchMaxBytes: expectedNativePatchMaxBytes,
        );
        final scope = scopes[arch]!;
        if (platform == ReleasePlatform.android) {
          final aot = artifacts.singleWhere((a) => a.arch == arch);
          if (aot.signing != signing) {
            throw const FormatException('Android AOT signing policy mismatch');
          }
          final bytes = await retrieve(aot);
          if (sha256.convert(bytes.readAsBytesSync()).toString() !=
              scope.baseArtifactHash) {
            throw const FormatException(
              'Separate Android AOT differs from final AAB library',
            );
          }
        }
        // Supplements are optional for native AOT, but any present supplement
        // must have the same key and independently verified stored bytes.
        final supplementArch = switch (platform) {
          ReleasePlatform.android => 'android_supplement',
          ReleasePlatform.linux =>
            arch == 'aarch64' ? 'linux_supplement_aarch64' : 'linux_supplement',
          _ =>
            arch == 'aarch64'
                ? 'windows_supplement_aarch64'
                : 'windows_supplement',
        };
        final supplements = artifacts
            .where((a) => a.arch == supplementArch)
            .toList();
        if (supplements.length > 1) {
          throw const FormatException('Duplicate native supplement');
        }
        final supplement = supplements.isEmpty ? null : supplements.single;
        if (supplement != null) {
          if (supplement.signing != signing) {
            throw const FormatException(
              'Native supplement signing policy mismatch',
            );
          }
          await retrieve(supplement);
        }
        if (register) {
          pending.add((
            scope: scope,
            primary: primary.id,
            supplement: supplement?.id,
          ));
        } else {
          final registration = registrations.singleWhere(
            (r) =>
                (r['scope'] as Map<String, dynamic>)['platform'] ==
                    platform.name &&
                (r['scope'] as Map<String, dynamic>)['arch'] == arch,
          );
          if (registration['release_artifact_id'] != primary.id ||
              registration['supplement_artifact_id'] != supplement?.id ||
              jsonEncode(
                    ReleaseSelectionScope.fromJson(
                      registration['scope'] as Map<String, dynamic>,
                    ).toJson(),
                  ) !=
                  jsonEncode(scope.toJson())) {
            throw const FormatException(
              'Staged registration differs from stored native package',
            );
          }
        }
      }
      for (final item in pending) {
        await client.registerReleaseSelectionScope(
          appId: appId,
          releaseId: release.id,
          scope: item.scope,
          releaseArtifactId: item.primary,
          supplementArtifactId: item.supplement,
        );
      }
    } finally {
      temp.deleteSync(recursive: true);
    }
  }
}
