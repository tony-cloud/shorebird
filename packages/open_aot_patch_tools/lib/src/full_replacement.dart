import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Largest component accepted by the replacement v1 runtime.
const fullReplacementMaxComponent = 128 * 1024 * 1024;

/// Largest manifest accepted by the replacement v1 runtime.
const fullReplacementMaxManifest = 4 * 1024 * 1024;

/// Largest UTF-8 URI accepted by the replacement v1 runtime.
const fullReplacementMaxUri = 16 * 1024;

/// Largest number of entries in each replacement URI set.
const fullReplacementMaxUris = 65536;

const _magic = [83, 66, 82, 80, 76, 67, 69, 0];
// UInt32 0x44424333 ('DBC3') in the component's little-endian format.
const _componentMagic = [0x33, 0x43, 0x42, 0x44];
// UInt32 0x44425033 ('DBP3'): a component encoded with a diversification
// profile (contract v3, docs/HARDENING_CONTRACTS.md §11.3). The magic is
// followed by format version 3 (UInt32) and the 32-byte profile digest.
const _profiledComponentMagic = [0x33, 0x50, 0x42, 0x44];
const _profiledComponentVersion = [3, 0, 0, 0];
const _profiledComponentHeaderSize = 4 + 4 + 32;
const _headerSize = 24;

/// A complete mutable-library domain, using the SDK replacement v1 format.
///
/// Digests provide consistency checks, not publisher authentication. This
/// manifest does not validate the semantics of the bytecode component.
class FullReplacementManifest {
  /// Creates and validates a manifest. URI sets must already be canonical.
  FullReplacementManifest({
    required List<int> hostAbi,
    required List<int> baselineDigest,
    required List<int> currentDigest,
    required this.rootUri,
    required List<String> baselineUris,
    required List<String> currentUris,
    required List<String> removedUris,
  }) : hostAbi = _digest(hostAbi),
       baselineDigest = _digest(baselineDigest),
       currentDigest = _digest(currentDigest),
       baselineUris = List.unmodifiable(baselineUris),
       currentUris = List.unmodifiable(currentUris),
       removedUris = List.unmodifiable(removedUris) {
    _validate();
  }

  /// SHA-256 identity of the immutable host ABI.
  final Uint8List hostAbi;

  /// SHA-256 of the originally released baseline component.
  final Uint8List baselineDigest;

  /// SHA-256 of the component carried by this wrapper.
  final Uint8List currentDigest;

  /// Entry library URI, present in both mutable domains.
  final String rootUri;

  /// Original baseline mutable libraries (B), in UTF-8 byte order.
  final List<String> baselineUris;

  /// Current complete mutable libraries (U), in UTF-8 byte order.
  final List<String> currentUris;

  /// Removed libraries (R), exactly B minus U in UTF-8 byte order.
  final List<String> removedUris;

  /// Lowercase hexadecimal host ABI identity.
  String get hostAbiHex => _hex(hostAbi);

  /// Lowercase hexadecimal baseline component SHA-256.
  String get baselineDigestHex => _hex(baselineDigest);

  /// Lowercase hexadecimal current component SHA-256.
  String get currentDigestHex => _hex(currentDigest);

  /// Whether this manifest describes a baseline rather than an update.
  bool get isBaseline =>
      _equal(baselineDigest, currentDigest) &&
      _equal(baselineUris, currentUris) &&
      removedUris.isEmpty;

  void _validate() {
    var encodedLength = 116;
    void uri(String value) {
      final bytes = utf8.encode(value);
      encodedLength += bytes.length;
      if (value.isEmpty ||
          value.contains('\u0000') ||
          bytes.length > fullReplacementMaxUri ||
          utf8.decode(bytes) != value) {
        throw const FormatException('Invalid replacement URI.');
      }
      if (encodedLength > fullReplacementMaxManifest) {
        throw const FormatException('Replacement manifest exceeds limit.');
      }
    }

    void set(List<String> values) {
      if (values.length > fullReplacementMaxUris) {
        throw const FormatException('Too many replacement URIs.');
      }
      encodedLength += 4 * values.length;
      for (var i = 0; i < values.length; i++) {
        uri(values[i]);
        if (values[i].startsWith('dart:') ||
            (i > 0 && _compare(values[i - 1], values[i]) >= 0)) {
          throw const FormatException(
            'Replacement URI sets must be canonical mutable-library sets.',
          );
        }
      }
    }

    uri(rootUri);
    set(baselineUris);
    set(currentUris);
    set(removedUris);
    if (!baselineUris.contains(rootUri) || !currentUris.contains(rootUri)) {
      throw const FormatException(
        'Replacement root is missing from the mutable domain.',
      );
    }
    final currentSet = currentUris.toSet();
    if (!_equal(
      baselineUris.where((uri) => !currentSet.contains(uri)).toList(),
      removedUris,
    )) {
      throw const FormatException(
        'Replacement removed URI set does not equal B minus U.',
      );
    }
  }

  Uint8List _encode() {
    final writer = _Writer()
      ..u32(1)
      ..bytes.add(hostAbi)
      ..bytes.add(baselineDigest)
      ..bytes.add(currentDigest)
      ..uri(rootUri);
    for (final values in [baselineUris, currentUris, removedUris]) {
      writer.u32(values.length);
      values.forEach(writer.uri);
    }
    return writer.bytes.takeBytes();
  }

  static FullReplacementManifest _decode(Uint8List bytes) {
    final reader = _Reader(bytes);
    if (reader.u32() != 1) {
      throw const FormatException('Unsupported replacement policy.');
    }
    final host = reader.take(32);
    final base = reader.take(32);
    final current = reader.take(32);
    final root = reader.uri();
    List<String> set() {
      final count = reader.u32();
      if (count > fullReplacementMaxUris || count > reader.remaining ~/ 5) {
        throw const FormatException('Invalid replacement URI set length.');
      }
      return List.generate(count, (_) => reader.uri());
    }

    final result = FullReplacementManifest(
      hostAbi: host,
      baselineDigest: base,
      currentDigest: current,
      rootUri: root,
      baselineUris: set(),
      currentUris: set(),
      removedUris: set(),
    );
    if (reader.remaining != 0) {
      throw const FormatException('Trailing replacement manifest bytes.');
    }
    return result;
  }
}

/// A validated SDK full replacement wrapper and its bytecode component.
///
/// The component is canonical `DBC3`, or `DBP3` encoded with the
/// diversification profile whose 32-byte digest is [bytecodeProfileDigest]
/// (contract v3). Each is accepted only when expected: a `DBP3` component
/// without an expected digest, a `DBC3` component with one, and a different
/// digest are refused.
///
/// Validation checks format and digest consistency. It does not authenticate
/// the publisher or verify bytecode semantics beyond the component header.
class FullReplacementBundle {
  /// Creates a wrapper after validating the component and its digest.
  FullReplacementBundle({
    required this.manifest,
    required List<int> component,
    List<int>? bytecodeProfileDigest,
  }) : bytecodeProfileDigest = bytecodeProfileDigest == null
           ? null
           : _digest(bytecodeProfileDigest),
       component = _component(component, bytecodeProfileDigest) {
    if (!_equal(sha256.convert(this.component).bytes, manifest.currentDigest)) {
      throw const FormatException('Replacement component digest mismatch.');
    }
  }

  /// Strictly decodes a replacement v1 wrapper, rejecting trailing bytes.
  ///
  /// [bytecodeProfileDigest] is the digest of the build's diversification
  /// profile, or null for a canonical build.
  factory FullReplacementBundle.decode(
    List<int> bytes, {
    List<int>? bytecodeProfileDigest,
  }) {
    if (bytes.length >
        _headerSize +
            fullReplacementMaxManifest +
            fullReplacementMaxComponent) {
      throw const FormatException('Replacement wrapper exceeds limit.');
    }
    final reader = _Reader(_copyBytes(bytes));
    if (!_equal(reader.take(8), _magic) || reader.u32() != 1) {
      throw const FormatException('Invalid replacement wrapper or version.');
    }
    final manifestLength = reader.u32();
    final componentLength = reader.u32();
    final high = reader.u32();
    if (high != 0 ||
        componentLength == 0 ||
        componentLength > fullReplacementMaxComponent ||
        manifestLength > fullReplacementMaxManifest ||
        manifestLength + componentLength != reader.remaining) {
      throw const FormatException('Invalid replacement wrapper lengths.');
    }
    final manifest = FullReplacementManifest._decode(
      reader.take(manifestLength),
    );
    return FullReplacementBundle(
      manifest: manifest,
      component: reader.take(componentLength),
      bytecodeProfileDigest: bytecodeProfileDigest,
    );
  }

  /// The immutable validated manifest.
  final FullReplacementManifest manifest;

  /// The immutable DBC3 or DBP3 component whose hash equals the current
  /// digest.
  final Uint8List component;

  /// The diversification profile digest the [component] is encoded with, or
  /// null for a canonical DBC3 component.
  final Uint8List? bytecodeProfileDigest;

  /// Encodes exactly the SDK replacement v1 binary format.
  Uint8List encode() {
    final metadata = manifest._encode();
    final writer = _Writer()
      ..bytes.add(_magic)
      ..u32(1)
      ..u32(metadata.length)
      ..u32(component.length)
      ..u32(0)
      ..bytes.add(metadata)
      ..bytes.add(component);
    return writer.bytes.takeBytes();
  }

  /// Rebases this same component as B = U, R = empty, base = current.
  ///
  /// This projection is intended for native diff-check archives. It preserves
  /// the host and root, but is not the original released baseline identity.
  FullReplacementBundle asBaseline() => FullReplacementBundle(
    manifest: FullReplacementManifest(
      hostAbi: manifest.hostAbi,
      baselineDigest: manifest.currentDigest,
      currentDigest: manifest.currentDigest,
      rootUri: manifest.rootUri,
      baselineUris: manifest.currentUris,
      currentUris: manifest.currentUris,
      removedUris: const [],
    ),
    component: component,
    bytecodeProfileDigest: bytecodeProfileDigest,
  );

  /// Binds this update to an original released baseline wrapper.
  ///
  /// Host ABI, baseline component digest, root and B must match exactly. New
  /// current libraries are permitted and removed libraries are already checked
  /// by the manifest's B minus U invariant.
  void validateUpdateAgainst(FullReplacementBundle releasedBase) {
    final base = releasedBase.manifest;
    if (!base.isBaseline) {
      throw const FormatException('Released replacement must be a baseline.');
    }
    if (!_equal(manifest.hostAbi, base.hostAbi) ||
        !_equal(manifest.baselineDigest, base.baselineDigest) ||
        manifest.rootUri != base.rootUri ||
        !_equal(manifest.baselineUris, base.baselineUris)) {
      throw const FormatException(
        'Replacement update does not match the released baseline.',
      );
    }
  }
}

Uint8List _digest(List<int> bytes) {
  if (bytes.length != 32) {
    throw const FormatException('Replacement digests must contain 32 bytes.');
  }
  return _copyBytes(bytes).asUnmodifiableView();
}

Uint8List _component(List<int> bytes, List<int>? profileDigest) {
  if (bytes.length < 4 || bytes.length > fullReplacementMaxComponent) {
    throw const FormatException('Invalid replacement component length.');
  }
  final magic = bytes.sublist(0, 4);
  if (profileDigest == null) {
    if (_equal(magic, _profiledComponentMagic)) {
      throw const FormatException(
        'Replacement component is DBP3 (diversified), but this build is '
        'canonical.',
      );
    }
    if (!_equal(magic, _componentMagic)) {
      throw const FormatException('Invalid replacement DBC3 component magic.');
    }
  } else {
    if (_equal(magic, _componentMagic)) {
      throw const FormatException(
        'Replacement component is DBC3 (canonical), but this build is '
        'diversified.',
      );
    }
    if (!_equal(magic, _profiledComponentMagic) ||
        bytes.length < _profiledComponentHeaderSize ||
        !_equal(bytes.sublist(4, 8), _profiledComponentVersion)) {
      throw const FormatException('Invalid replacement DBP3 component header.');
    }
    if (!_equal(
      bytes.sublist(8, _profiledComponentHeaderSize),
      profileDigest,
    )) {
      throw const FormatException(
        'Replacement DBP3 component names a different bytecode profile.',
      );
    }
  }
  return _copyBytes(bytes).asUnmodifiableView();
}

Uint8List _copyBytes(List<int> bytes) {
  if (bytes is! Uint8List && bytes.any((byte) => byte < 0 || byte > 255)) {
    throw const FormatException('Replacement data contains an invalid byte.');
  }
  return Uint8List.fromList(bytes);
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

bool _equal<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int _compare(String a, String b) {
  final aa = utf8.encode(a);
  final bb = utf8.encode(b);
  for (var i = 0; i < aa.length && i < bb.length; i++) {
    if (aa[i] != bb[i]) return aa[i].compareTo(bb[i]);
  }
  return aa.length.compareTo(bb.length);
}

class _Writer {
  final bytes = BytesBuilder(copy: false);

  void u32(int value) {
    final data = ByteData(4)..setUint32(0, value, Endian.little);
    bytes.add(data.buffer.asUint8List());
  }

  void uri(String value) {
    final encoded = utf8.encode(value);
    u32(encoded.length);
    bytes.add(encoded);
  }
}

class _Reader {
  _Reader(this.bytes);

  final Uint8List bytes;
  int offset = 0;

  int get remaining => bytes.length - offset;

  Uint8List take(int count) {
    if (count < 0 || count > remaining) {
      throw const FormatException('Truncated replacement data.');
    }
    final result = Uint8List.sublistView(bytes, offset, offset + count);
    offset += count;
    return result;
  }

  int u32() => ByteData.sublistView(take(4)).getUint32(0, Endian.little);

  String uri() {
    final length = u32();
    if (length == 0 || length > fullReplacementMaxUri) {
      throw const FormatException('Invalid replacement URI length.');
    }
    return utf8.decode(take(length), allowMalformed: false);
  }
}
