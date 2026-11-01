import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:shorebird_cli/src/archive_analysis/native_selection_archive.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';

const nativeAppId = '11111111-1111-4111-8111-111111111111';
const nativeVersion = '1.0.0+1';

List<int> nativeElf(String arch, {int content = 1}) {
  final bytes = Uint8List(32)
    ..setAll(0, [0x7f, 0x45, 0x4c, 0x46, if (arch == 'arm') 1 else 2, 1]);
  ByteData.sublistView(bytes).setUint16(18, switch (arch) {
    'arm' => 40,
    'aarch64' => 183,
    _ => 62,
  }, Endian.little);
  bytes[24] = content;
  return bytes;
}

Map<String, ReleaseSelectionScope> nativeScopes(
  String platform,
  Map<String, List<int>> libraries,
) => {
  for (final entry in libraries.entries)
    entry.key: ReleaseSelectionScope(
      appId: nativeAppId,
      releaseVersion: nativeVersion,
      platform: platform,
      arch: entry.key,
      baseArtifactHash: sha256.convert(entry.value).toString(),
      hostAbiHash: null,
      runtimeProfile: 'native-aot',
    ),
};

File nativePackage(
  String path, {
  String platform = 'android',
  Map<String, List<int>>? libraries,
  Map<String, ReleaseSelectionScope>? scopes,
  Map<String, Object?> policy = const {},
  Map<String, List<int>> extraMembers = const {},
  bool omitScopes = false,
  String? assetsPrefix,
}) {
  libraries ??= {'aarch64': nativeElf('aarch64')};
  scopes ??= nativeScopes(platform, libraries);
  final prefix =
      assetsPrefix ??
      (platform == 'android'
          ? 'base/assets/flutter_assets'
          : 'data/flutter_assets');
  final members = <String, List<int>>{
    for (final entry in libraries.entries)
      NativeSelectionArchive.libraryPath(platform, entry.key): entry.value,
    '$prefix/shorebird.yaml': utf8.encode(
      jsonEncode({
        'app_id': nativeAppId,
        'selection_protocol': 2,
        'aot_patch_app_build_id': nativeVersion,
        'patch_verification': 'strict',
        'patch_response_verification': 'required',
        'patch_public_key': 'pinned-key',
        ...policy,
      }),
    ),
    if (!omitScopes)
      for (final scope in scopes.values)
        '$prefix/${scope.assetName}': utf8.encode(jsonEncode(scope.toJson())),
    ...extraMembers,
  };
  final archive = Archive();
  for (final entry in members.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return File(path)..writeAsBytesSync(ZipEncoder().encode(archive));
}
