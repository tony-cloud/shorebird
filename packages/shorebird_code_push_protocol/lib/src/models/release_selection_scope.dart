import 'dart:convert';

import 'package:meta/meta.dart';

/// Exact immutable runtime identity bundled in a protocol-2 release.
@immutable
class ReleaseSelectionScope {
  /// Creates and validates an immutable installed runtime scope.
  ReleaseSelectionScope({
    required this.appId,
    required this.releaseVersion,
    required this.platform,
    required this.arch,
    required this.baseArtifactHash,
    required this.hostAbiHash,
    required this.runtimeProfile,
  }) {
    if (!RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        ).hasMatch(appId) ||
        releaseVersion.isEmpty ||
        !const {
          'android',
          'ios',
          'macos',
          'windows',
          'linux',
        }.contains(platform) ||
        !const {'arm', 'aarch64', 'x86', 'x86_64'}.contains(arch) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(baseArtifactHash) ||
        !const {
          'native-aot',
          'interpreter-body',
          'interpreter-structural',
          'interpreter-full',
        }.contains(runtimeProfile) ||
        (runtimeProfile == 'interpreter-full'
            ? hostAbiHash == null ||
                  !RegExp(r'^[0-9a-f]{64}$').hasMatch(hostAbiHash!)
            : hostAbiHash != null)) {
      throw const FormatException('Invalid immutable release selection scope');
    }
  }

  /// Decodes the flat public object without silently merging duplicate keys.
  factory ReleaseSelectionScope.decode(String source) {
    var offset = 0;
    void whitespace() {
      while (offset < source.length &&
          const {0x20, 0x09, 0x0a, 0x0d}.contains(source.codeUnitAt(offset))) {
        offset++;
      }
    }

    void consume(String token) {
      whitespace();
      if (!source.startsWith(token, offset)) {
        throw const FormatException('Invalid release scope JSON');
      }
      offset += token.length;
    }

    String string() {
      whitespace();
      final start = offset;
      consume('"');
      while (offset < source.length) {
        final character = source.codeUnitAt(offset++);
        if (character == 0x5c) {
          offset++;
        } else if (character == 0x22) {
          return jsonDecode(source.substring(start, offset)) as String;
        }
      }
      throw const FormatException('Unterminated release scope JSON string');
    }

    consume('{');
    final fields = <String, dynamic>{};
    whitespace();
    if (!source.startsWith('}', offset)) {
      while (true) {
        final key = string();
        if (fields.containsKey(key)) {
          throw const FormatException('Duplicate release scope field');
        }
        consume(':');
        whitespace();
        if (source.startsWith('null', offset)) {
          consume('null');
          fields[key] = null;
        } else {
          fields[key] = string();
        }
        whitespace();
        if (source.startsWith('}', offset)) break;
        consume(',');
      }
    }
    consume('}');
    whitespace();
    if (offset != source.length) {
      throw const FormatException('Trailing release scope JSON');
    }
    return ReleaseSelectionScope.fromJson(fields);
  }

  /// Rejects missing, extra and incorrectly typed runtime identity fields.
  factory ReleaseSelectionScope.fromJson(Map<String, dynamic> json) {
    const keys = {
      'app_id',
      'release_version',
      'platform',
      'arch',
      'base_artifact_hash',
      'host_abi_hash',
      'runtime_profile',
    };
    if (json.length != keys.length || !json.keys.toSet().containsAll(keys)) {
      throw const FormatException(
        'Release scope must contain exactly seven fields',
      );
    }
    return ReleaseSelectionScope(
      appId: json['app_id'] as String,
      releaseVersion: json['release_version'] as String,
      platform: json['platform'] as String,
      arch: json['arch'] as String,
      baseArtifactHash: json['base_artifact_hash'] as String,
      hostAbiHash: json['host_abi_hash'] as String?,
      runtimeProfile: json['runtime_profile'] as String,
    );
  }

  /// Installed application UUID.
  final String appId;

  /// Exact installed release version.
  final String releaseVersion;

  /// Updater platform.
  final String platform;

  /// Updater wire architecture.
  final String arch;

  /// SHA-256 of the exact original runtime baseline.
  final String baseArtifactHash;

  /// Existing measured full replacement host ABI, otherwise null.
  final String? hostAbiHash;

  /// Immutable compiler/runtime profile.
  final String runtimeProfile;

  /// Fixed public asset name, independent of build flavor or variant.
  String get assetName => 'shorebird_release_scope_${platform}_$arch.json';

  /// Exact compiled representation, including required null.
  Map<String, dynamic> toJson() => {
    'app_id': appId,
    'release_version': releaseVersion,
    'platform': platform,
    'arch': arch,
    'base_artifact_hash': baseArtifactHash,
    'host_abi_hash': hostAbiHash,
    'runtime_profile': runtimeProfile,
  };

  /// Registration body referencing separately uploaded package and supplement.
  Map<String, dynamic> registrationJson({
    required int releaseArtifactId,
    required int? supplementArtifactId,
  }) => {
    'base_artifact_hash': baseArtifactHash,
    'host_abi_hash': hostAbiHash,
    'runtime_profile': runtimeProfile,
    'release_artifact_id': releaseArtifactId,
    'supplement_artifact_id': supplementArtifactId,
  };
}
