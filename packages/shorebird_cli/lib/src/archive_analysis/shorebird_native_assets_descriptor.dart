import 'dart:convert';

import 'package:archive/archive_io.dart';

/// Validates the compiler's explicit native-mapping provenance asset.
class ShorebirdNativeAssetsDescriptor {
  ShorebirdNativeAssetsDescriptor._();

  /// Asset-root filename shared with the compiler and Flutter bundler.
  static const assetName = 'shorebird_native_assets.json';

  static final _assetPath = RegExp(
    r'(^|/)flutter_assets/shorebird_native_assets\.json$',
  );
  static final _digest = RegExp(r'^[0-9a-f]{64}$');

  /// Whether [path] identifies the descriptor at a Flutter asset root.
  static bool isAssetPath(String path) => _assetPath.hasMatch(path);

  /// Returns the validated fixed-order JSON body without its optional final LF.
  ///
  /// Re-encoding rejects duplicate keys, unknown fields, alternate key order,
  /// ambiguous numeric types and noncanonical JSON without a custom parser.
  static String canonicalBody(ArchiveFile file, {String? target}) {
    if (!file.isFile ||
        file.isSymbolicLink ||
        file.size <= 0 ||
        file.size > 4096) {
      throw const FormatException(
        'Native mapping descriptor must be a bounded regular file.',
      );
    }
    final bytes = file.content as List<int>;
    if (bytes.length >= 3 &&
        bytes[0] == 0xef &&
        bytes[1] == 0xbb &&
        bytes[2] == 0xbf) {
      throw const FormatException(
        'Noncanonical native mapping descriptor BOM.',
      );
    }
    final contents = utf8.decode(bytes);
    final body = contents.endsWith('\n')
        ? contents.substring(0, contents.length - 1)
        : contents;
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic> ||
        decoded['schema'] is! int ||
        decoded['schema'] != 1 ||
        !const ['ios_arm64', 'macos_arm64'].contains(decoded['target']) ||
        (target != null && decoded['target'] != target) ||
        decoded['carrier_present'] is! bool) {
      throw const FormatException('Invalid native mapping descriptor schema.');
    }
    final present = decoded['carrier_present'] as bool;
    final digest = decoded['mapping_sha256'];
    if ((present && (digest is! String || !_digest.hasMatch(digest))) ||
        decoded.length != (present ? 4 : 3)) {
      throw const FormatException('Invalid native mapping descriptor fields.');
    }
    final canonical = jsonEncode({
      'schema': 1,
      'target': decoded['target'],
      'carrier_present': present,
      if (present) 'mapping_sha256': digest,
    });
    if (body != canonical) {
      throw const FormatException('Noncanonical native mapping descriptor.');
    }
    return canonical;
  }
}
