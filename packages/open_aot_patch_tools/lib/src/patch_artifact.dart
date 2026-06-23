import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

/// JSON format marker for an unencrypted compact AOT patch artifact.
const artifactFormat = 'open-aot-vmcode-v1';

/// JSON format marker for an AES-GCM encrypted compact AOT patch artifact.
const encryptedArtifactFormat = 'open-aot-vmcode-encrypted-v1';

/// Payload kind used when the patch snapshot is identical to the base.
const payloadKindEmpty = 'empty';

/// Payload kind used when the artifact stores the full patch snapshot.
const payloadKindFullSnapshot = 'full-snapshot';

/// Payload kind used when the artifact stores an open binary diff.
const payloadKindBinaryDiff = 'binary-diff-v1';

/// Compatibility metadata bound to a compact AOT patch artifact.
class PatchMetadata {
  /// Creates patch metadata for one application build and flavor.
  const PatchMetadata({
    required this.appId,
    required this.appBuildId,
    required this.flavorId,
    required this.licenseType,
    required this.sdkHash,
    required this.baseSnapshotHash,
    required this.patchSnapshotHash,
    required this.targetOs,
    required this.targetArch,
    this.baseFlavorId,
    this.baseLicenseType,
    this.obfuscationMapHash,
  });

  /// Reads metadata from the JSON representation used by patch artifacts.
  factory PatchMetadata.fromJson(Map<String, Object?> json) => PatchMetadata(
    appId: _string(json, 'app_id'),
    appBuildId: _string(json, 'app_build_id'),
    baseFlavorId: json['base_flavor_id'] as String?,
    baseLicenseType: json['base_license_type'] as String?,
    flavorId: _string(json, 'flavor_id'),
    licenseType: _string(json, 'license_type'),
    sdkHash: _string(json, 'sdk_hash'),
    baseSnapshotHash: _string(json, 'base_snapshot_hash'),
    patchSnapshotHash: _string(json, 'patch_snapshot_hash'),
    targetOs: _string(json, 'target_os'),
    targetArch: _string(json, 'target_arch'),
    obfuscationMapHash: json['obfuscation_map_hash'] as String?,
  );

  /// Stable application identifier.
  final String appId;

  /// Application build identifier that produced the base snapshot.
  final String appBuildId;

  /// Optional source flavor this patch is allowed to replace.
  final String? baseFlavorId;

  /// Optional source license type this patch is allowed to replace.
  final String? baseLicenseType;

  /// Target flavor after the patch is applied.
  final String flavorId;

  /// Target license type after the patch is applied.
  final String licenseType;

  /// Hash identifying the Dart/Flutter SDK build.
  final String sdkHash;

  /// SHA-256 hash of the base snapshot bytes.
  final String baseSnapshotHash;

  /// SHA-256 hash of the reconstructed patch snapshot bytes.
  final String patchSnapshotHash;

  /// Target operating system, for example `windows` or `ios`.
  final String targetOs;

  /// Target CPU architecture, for example `x64` or `arm64`.
  final String targetArch;

  /// Optional hash of the obfuscation map used by base and patch builds.
  final String? obfuscationMapHash;

  /// Converts this metadata to the stable JSON map used as AES-GCM AAD.
  Map<String, Object?> toJson() => {
    'app_id': appId,
    'app_build_id': appBuildId,
    if (baseFlavorId != null) 'base_flavor_id': baseFlavorId,
    if (baseLicenseType != null) 'base_license_type': baseLicenseType,
    'flavor_id': flavorId,
    'license_type': licenseType,
    'sdk_hash': sdkHash,
    'base_snapshot_hash': baseSnapshotHash,
    'patch_snapshot_hash': patchSnapshotHash,
    'target_os': targetOs,
    'target_arch': targetArch,
    if (obfuscationMapHash != null) 'obfuscation_map_hash': obfuscationMapHash,
  };
}

/// Unencrypted compact patch artifact.
class PatchArtifact {
  /// Creates an unencrypted compact patch artifact.
  const PatchArtifact({
    required this.metadata,
    required this.payload,
    required this.payloadKind,
    required this.reconstructedSize,
  });

  /// Reads and validates an unencrypted patch artifact JSON map.
  factory PatchArtifact.fromJson(Map<String, Object?> json) {
    final format = json['format'];
    if (format != artifactFormat) {
      throw FormatException('Unsupported artifact format: $format');
    }
    final payloadKind =
        json['payload_kind'] as String? ?? payloadKindFullSnapshot;
    final payload = base64Decode(_string(json, 'payload_base64'));
    final payloadHash = json['payload_sha256'] as String?;
    if (payloadHash != null && payloadHash != sha256Hex(payload)) {
      throw const FormatException('Patch payload hash mismatch.');
    }
    return PatchArtifact(
      metadata: PatchMetadata.fromJson(
        (json['metadata']! as Map).cast<String, Object?>(),
      ),
      payload: payload,
      payloadKind: payloadKind,
      reconstructedSize: (json['reconstructed_size'] as num?)?.toInt(),
    );
  }

  /// Metadata used to validate app, SDK, flavor, and snapshot compatibility.
  final PatchMetadata metadata;

  /// Compact payload bytes, whose interpretation depends on [payloadKind].
  final List<int> payload;

  /// One of the `payloadKind*` constants.
  final String payloadKind;

  /// Expected byte length of the reconstructed patch snapshot.
  final int? reconstructedSize;

  /// Converts this artifact to its JSON representation.
  Map<String, Object?> toJson() => {
    'format': artifactFormat,
    'metadata': metadata.toJson(),
    'payload_kind': payloadKind,
    if (reconstructedSize != null) 'reconstructed_size': reconstructedSize,
    'payload_sha256': sha256Hex(payload),
    'payload_base64': base64Encode(payload),
  };

  /// Reconstructs the final patch snapshot from [baseSnapshot].
  List<int> reconstruct(List<int> baseSnapshot) => reconstructPatchSnapshot(
    baseSnapshot: baseSnapshot,
    payload: payload,
    payloadKind: payloadKind,
    reconstructedSize: reconstructedSize,
  );
}

/// AES-256-GCM encrypted compact patch artifact.
class EncryptedPatchArtifact {
  /// Creates an encrypted compact patch artifact.
  const EncryptedPatchArtifact({
    required this.metadata,
    required this.encryptedPayload,
    required this.payloadKind,
    required this.reconstructedSize,
    required this.keyId,
    required this.nonce,
    required this.tag,
    required this.aadSha256,
    required this.payloadSha256,
  });

  /// Reads and validates an encrypted patch artifact JSON map.
  factory EncryptedPatchArtifact.fromJson(Map<String, Object?> json) {
    final format = json['format'];
    if (format != encryptedArtifactFormat) {
      throw FormatException('Unsupported encrypted artifact format: $format');
    }
    final encryption = (json['encryption']! as Map).cast<String, Object?>();
    if (encryption['algorithm'] != 'AES-256-GCM') {
      throw FormatException(
        'Unsupported encryption algorithm: ${encryption['algorithm']}',
      );
    }
    return EncryptedPatchArtifact(
      metadata: PatchMetadata.fromJson(
        (json['metadata']! as Map).cast<String, Object?>(),
      ),
      encryptedPayload: base64Decode(_string(json, 'encrypted_payload_base64')),
      payloadKind: json['payload_kind'] as String? ?? payloadKindFullSnapshot,
      reconstructedSize: (json['reconstructed_size'] as num?)?.toInt(),
      keyId: _string(encryption, 'key_id'),
      nonce: base64Decode(_string(encryption, 'nonce_base64')),
      tag: base64Decode(_string(encryption, 'tag_base64')),
      aadSha256: _string(encryption, 'aad_sha256'),
      payloadSha256: _string(json, 'payload_sha256'),
    );
  }

  /// Metadata used to validate app, SDK, flavor, and snapshot compatibility.
  final PatchMetadata metadata;

  /// AES-GCM ciphertext bytes without the authentication tag.
  final List<int> encryptedPayload;

  /// One of the `payloadKind*` constants.
  final String payloadKind;

  /// Expected byte length of the reconstructed patch snapshot.
  final int? reconstructedSize;

  /// Key identifier supplied to the app-owned key callback.
  final String keyId;

  /// AES-GCM nonce bytes.
  final List<int> nonce;

  /// AES-GCM authentication tag bytes.
  final List<int> tag;

  /// SHA-256 hash of the canonical metadata AAD.
  final String aadSha256;

  /// SHA-256 hash of the decrypted compact payload bytes.
  final String payloadSha256;

  /// Converts this encrypted artifact to its JSON representation.
  Map<String, Object?> toJson() => {
    'format': encryptedArtifactFormat,
    'metadata': metadata.toJson(),
    'payload_kind': payloadKind,
    if (reconstructedSize != null) 'reconstructed_size': reconstructedSize,
    'payload_sha256': payloadSha256,
    'encrypted_payload_base64': base64Encode(encryptedPayload),
    'encryption': {
      'algorithm': 'AES-256-GCM',
      'key_id': keyId,
      'nonce_base64': base64Encode(nonce),
      'tag_base64': base64Encode(tag),
      'aad_sha256': aadSha256,
    },
  };

  /// Decrypts and authenticates the compact payload with [key].
  PatchArtifact decrypt(List<int> key) {
    final aad = canonicalJson(metadata.toJson());
    final actualAadSha = sha256Hex(utf8.encode(aad));
    if (actualAadSha != aadSha256) {
      throw const FormatException('Artifact metadata AAD hash mismatch.');
    }
    final cipherTextAndTag = Uint8List.fromList([...encryptedPayload, ...tag]);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
          KeyParameter(Uint8List.fromList(key)),
          tag.length * 8,
          Uint8List.fromList(nonce),
          Uint8List.fromList(utf8.encode(aad)),
        ),
      );
    final Uint8List payload;
    try {
      payload = cipher.process(cipherTextAndTag);
    } on Object catch (error) {
      throw FormatException('Patch decryption failed: $error');
    }
    if (sha256Hex(payload) != payloadSha256) {
      throw const FormatException('Decrypted payload hash mismatch.');
    }
    return PatchArtifact(
      metadata: metadata,
      payload: payload,
      payloadKind: payloadKind,
      reconstructedSize: reconstructedSize,
    );
  }
}

/// Links base and patch snapshot bytes into a compact patch artifact.
PatchArtifact linkArtifacts({
  required List<int> baseSnapshot,
  required List<int> patchSnapshot,
  required PatchMetadata metadata,
  bool forceFullSnapshot = false,
}) {
  final compact = forceFullSnapshot
      ? _CompactPayload(
          kind: payloadKindFullSnapshot,
          payload: List<int>.of(patchSnapshot),
          reconstructedSize: patchSnapshot.length,
        )
      : _compactPayload(baseSnapshot, patchSnapshot);
  return PatchArtifact(
    metadata: metadata,
    payload: compact.payload,
    payloadKind: compact.kind,
    reconstructedSize: compact.reconstructedSize,
  );
}

/// Encrypts a compact patch artifact for secure delivery.
EncryptedPatchArtifact encryptArtifact({
  required PatchArtifact artifact,
  required String keyId,
  required List<int> key,
  required List<int> nonce,
}) {
  if (key.length != 32) {
    throw ArgumentError.value(
      key.length,
      'key.length',
      'AES-256 needs 32 bytes',
    );
  }
  if (nonce.length != 12) {
    throw ArgumentError.value(
      nonce.length,
      'nonce.length',
      'AES-GCM nonce must be 12 bytes',
    );
  }
  final aad = canonicalJson(artifact.metadata.toJson());
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      true,
      AEADParameters(
        KeyParameter(Uint8List.fromList(key)),
        128,
        Uint8List.fromList(nonce),
        Uint8List.fromList(utf8.encode(aad)),
      ),
    );
  final sealed = cipher.process(Uint8List.fromList(artifact.payload));
  return EncryptedPatchArtifact(
    metadata: artifact.metadata,
    encryptedPayload: sealed.sublist(0, sealed.length - 16),
    payloadKind: artifact.payloadKind,
    reconstructedSize: artifact.reconstructedSize,
    keyId: keyId,
    nonce: nonce,
    tag: sealed.sublist(sealed.length - 16),
    aadSha256: sha256Hex(utf8.encode(aad)),
    payloadSha256: sha256Hex(artifact.payload),
  );
}

/// Verifies that metadata matches the expected target and optional base state.
void verifyMetadata(
  PatchMetadata metadata, {
  required String flavorId,
  required String licenseType,
  String? baseFlavorId,
  String? baseLicenseType,
}) {
  if (baseFlavorId != null && metadata.baseFlavorId != baseFlavorId) {
    throw StateError(
      'Patch base flavor "${metadata.baseFlavorId}" does not match '
      '"$baseFlavorId".',
    );
  }
  if (baseLicenseType != null && metadata.baseLicenseType != baseLicenseType) {
    throw StateError(
      'Patch base license "${metadata.baseLicenseType}" does not match '
      '"$baseLicenseType".',
    );
  }
  if (metadata.flavorId != flavorId) {
    throw StateError(
      'Patch flavor "${metadata.flavorId}" does not match "$flavorId".',
    );
  }
  if (metadata.licenseType != licenseType) {
    throw StateError(
      'Patch license "${metadata.licenseType}" does not match "$licenseType".',
    );
  }
}

/// Reconstructs final patch snapshot bytes from a compact payload.
List<int> reconstructPatchSnapshot({
  required List<int> baseSnapshot,
  required List<int> payload,
  required String payloadKind,
  required int? reconstructedSize,
}) {
  switch (payloadKind) {
    case payloadKindEmpty:
      return List<int>.of(baseSnapshot);
    case payloadKindFullSnapshot:
      return List<int>.of(payload);
    case payloadKindBinaryDiff:
      if (reconstructedSize == null) {
        throw const FormatException(
          'Binary diff payload is missing reconstructed_size.',
        );
      }
      return _applyBinaryDiff(
        baseSnapshot: baseSnapshot,
        diff: payload,
        reconstructedSize: reconstructedSize,
      );
    default:
      throw FormatException('Unsupported payload kind: $payloadKind');
  }
}

/// Encodes [value] as deterministic JSON with sorted map keys.
String canonicalJson(Object? value) {
  Object? normalize(Object? input) {
    if (input is Map) {
      final keys = input.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: normalize(input[key])};
    }
    if (input is Iterable) {
      return input.map(normalize).toList();
    }
    return input;
  }

  return jsonEncode(normalize(value));
}

/// Computes a lowercase hexadecimal SHA-256 digest for [bytes].
String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// Reads a 32-byte AES key from hexadecimal text.
List<int> readKey(String keyHex) {
  return readHexBytes(keyHex, expectedBytes: 32, name: 'AES-256 key');
}

/// Reads a 12-byte AES-GCM nonce from hexadecimal text.
List<int> readNonce(String nonceHex) {
  return readHexBytes(nonceHex, expectedBytes: 12, name: 'AES-GCM nonce');
}

/// Reads exactly [expectedBytes] bytes from hexadecimal text.
List<int> readHexBytes(
  String hex, {
  required int expectedBytes,
  required String name,
}) {
  final normalized = hex.trim();
  if (normalized.length != expectedBytes * 2) {
    throw ArgumentError('$name must be ${expectedBytes * 2} hex characters.');
  }
  return [
    for (var i = 0; i < normalized.length; i += 2)
      int.parse(normalized.substring(i, i + 2), radix: 16),
  ];
}

/// Reads a JSON object from [file].
Map<String, Object?> readJsonFile(File file) =>
    (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>();

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('Expected non-empty string field "$key".');
  }
  return value;
}

_CompactPayload _compactPayload(
  List<int> baseSnapshot,
  List<int> patchSnapshot,
) {
  if (_listEquals(baseSnapshot, patchSnapshot)) {
    return _CompactPayload(
      kind: payloadKindEmpty,
      payload: const [],
      reconstructedSize: patchSnapshot.length,
    );
  }

  final diff = _encodeBinaryDiff(
    baseSnapshot: baseSnapshot,
    patchSnapshot: patchSnapshot,
  );
  if (diff.length < patchSnapshot.length) {
    return _CompactPayload(
      kind: payloadKindBinaryDiff,
      payload: diff,
      reconstructedSize: patchSnapshot.length,
    );
  }
  return _CompactPayload(
    kind: payloadKindFullSnapshot,
    payload: List<int>.of(patchSnapshot),
    reconstructedSize: patchSnapshot.length,
  );
}

class _CompactPayload {
  const _CompactPayload({
    required this.kind,
    required this.payload,
    required this.reconstructedSize,
  });

  final String kind;
  final List<int> payload;
  final int reconstructedSize;
}

List<int> _encodeBinaryDiff({
  required List<int> baseSnapshot,
  required List<int> patchSnapshot,
}) {
  const magic = [0x4f, 0x41, 0x50, 0x44, 0x31]; // OAPD1.
  const equalGapToKeep = 16;
  final chunks = <_DiffChunk>[];
  var cursor = 0;
  while (cursor < patchSnapshot.length) {
    final baseByte = cursor < baseSnapshot.length ? baseSnapshot[cursor] : null;
    if (baseByte == patchSnapshot[cursor]) {
      cursor++;
      continue;
    }

    final start = cursor;
    var lastDifferent = cursor;
    var equalRun = 0;
    cursor++;
    while (cursor < patchSnapshot.length) {
      final baseAtCursor = cursor < baseSnapshot.length
          ? baseSnapshot[cursor]
          : null;
      if (baseAtCursor == patchSnapshot[cursor]) {
        equalRun++;
        if (equalRun > equalGapToKeep) {
          break;
        }
      } else {
        equalRun = 0;
        lastDifferent = cursor;
      }
      cursor++;
    }

    final end = lastDifferent + 1;
    chunks.add(_DiffChunk(start, patchSnapshot.sublist(start, end)));
    cursor = end;
  }

  final size =
      magic.length +
      8 +
      4 +
      chunks.fold<int>(
        0,
        (total, chunk) => total + 8 + 4 + chunk.bytes.length,
      );
  final output = Uint8List(size);
  var offset = 0;
  output.setRange(offset, offset + magic.length, magic);
  offset += magic.length;
  _writeUint64(output, offset, patchSnapshot.length);
  offset += 8;
  _writeUint32(output, offset, chunks.length);
  offset += 4;
  for (final chunk in chunks) {
    _writeUint64(output, offset, chunk.offset);
    offset += 8;
    _writeUint32(output, offset, chunk.bytes.length);
    offset += 4;
    output.setRange(offset, offset + chunk.bytes.length, chunk.bytes);
    offset += chunk.bytes.length;
  }
  return output;
}

List<int> _applyBinaryDiff({
  required List<int> baseSnapshot,
  required List<int> diff,
  required int reconstructedSize,
}) {
  const magic = [0x4f, 0x41, 0x50, 0x44, 0x31]; // OAPD1.
  if (diff.length < magic.length + 8 + 4) {
    throw const FormatException('Binary diff payload is too short.');
  }
  for (var i = 0; i < magic.length; i++) {
    if (diff[i] != magic[i]) {
      throw const FormatException('Invalid binary diff magic.');
    }
  }
  var cursor = magic.length;
  final targetSize = _readUint64(diff, cursor);
  cursor += 8;
  if (targetSize != reconstructedSize) {
    throw const FormatException('Binary diff target size mismatch.');
  }
  final chunkCount = _readUint32(diff, cursor);
  cursor += 4;

  final output = Uint8List(reconstructedSize);
  final copied = baseSnapshot.length < reconstructedSize
      ? baseSnapshot.length
      : reconstructedSize;
  output.setRange(0, copied, baseSnapshot);

  for (var i = 0; i < chunkCount; i++) {
    if (cursor + 12 > diff.length) {
      throw const FormatException('Truncated binary diff chunk header.');
    }
    final chunkOffset = _readUint64(diff, cursor);
    cursor += 8;
    final chunkLength = _readUint32(diff, cursor);
    cursor += 4;
    if (chunkOffset < 0 ||
        chunkLength < 0 ||
        chunkOffset + chunkLength > reconstructedSize ||
        cursor + chunkLength > diff.length) {
      throw const FormatException('Invalid binary diff chunk bounds.');
    }
    output.setRange(
      chunkOffset,
      chunkOffset + chunkLength,
      diff,
      cursor,
    );
    cursor += chunkLength;
  }
  if (cursor != diff.length) {
    throw const FormatException('Unexpected trailing binary diff data.');
  }
  return output;
}

class _DiffChunk {
  const _DiffChunk(this.offset, this.bytes);

  final int offset;
  final List<int> bytes;
}

void _writeUint32(Uint8List output, int offset, int value) {
  output[offset] = value & 0xff;
  output[offset + 1] = (value >> 8) & 0xff;
  output[offset + 2] = (value >> 16) & 0xff;
  output[offset + 3] = (value >> 24) & 0xff;
}

void _writeUint64(Uint8List output, int offset, int value) {
  for (var i = 0; i < 8; i++) {
    output[offset + i] = (value >> (8 * i)) & 0xff;
  }
}

int _readUint32(List<int> input, int offset) {
  return input[offset] |
      (input[offset + 1] << 8) |
      (input[offset + 2] << 16) |
      (input[offset + 3] << 24);
}

int _readUint64(List<int> input, int offset) {
  var value = 0;
  for (var i = 0; i < 8; i++) {
    value |= input[offset + i] << (8 * i);
  }
  return value;
}

bool _listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
