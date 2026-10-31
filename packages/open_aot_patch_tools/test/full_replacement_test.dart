import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:open_aot_patch_tools/open_aot_patch_tools.dart';
import 'package:test/test.dart';

const _root = 'package:app/main.dart';
const _old = 'package:app/old.dart';
const _new = 'package:app/new.dart';
const _baseComponent = [0x33, 0x43, 0x42, 0x44, 0];
const _component = [0x33, 0x43, 0x42, 0x44, 7, 8, 9];

// SDK encodeShorebirdReplacement fixture: host = bytes 0..31; B = main/old;
// U = main/new; R = old; base/current are SHA-256 of the components above.
const _sdkFixture =
    'U0JSUExDRQABAAAAAwEAAAcAAAAAAAAAAQAAAAABAgMEBQYHCAkKCwwNDg8QERITFBUW'
    'FxgZGhscHR4f6Y5zqo3s2+9sQFhZgkZ2P/6JN8e2FMRRP/I5My26vlDkerqjj7U/'
    'k8n2NDCNa9ns2z04OpLQnr2iHDdd0r7wARUAAABwYWNrYWdlOmFwcC9tYWluLmRh'
    'cnQCAAAAFQAAAHBhY2thZ2U6YXBwL21haW4uZGFydBQAAABwYWNrYWdlOmFwcC9v'
    'bGQuZGFydAIAAAAVAAAAcGFja2FnZTphcHAvbWFpbi5kYXJ0FAAAAHBhY2thZ2U6YX'
    'BwL25ldy5kYXJ0AQAAABQAAABwYWNrYWdlOmFwcC9vbGQuZGFydDNDQkQHCAk=';

void main() {
  group('FullReplacementBundle', () {
    test('decodes and exactly re-encodes the SDK binary fixture', () {
      final bytes = base64Decode(_sdkFixture);
      final bundle = FullReplacementBundle.decode(bytes);
      expect(bundle.encode(), bytes);
      expect(_update().encode(), bytes);
      expect(bundle.component, _component);
      expect(
        bundle.manifest.hostAbiHex,
        List.generate(32, (i) => i.toRadixString(16).padLeft(2, '0')).join(),
      );
      expect(bundle.manifest.baselineDigestHex, sha256Hex(_baseComponent));
      expect(bundle.manifest.currentDigestHex, sha256Hex(_component));
      expect(bundle.manifest.rootUri, _root);
      expect(bundle.manifest.baselineUris, [_root, _old]);
      expect(bundle.manifest.currentUris, [_root, _new]);
      expect(bundle.manifest.removedUris, [_old]);
      expect(bundle.manifest.isBaseline, isFalse);
      bundle.validateUpdateAgainst(_base());
    });

    test('rejects every truncated prefix', () {
      final bytes = base64Decode(_sdkFixture);
      for (var i = 0; i < bytes.length; i++) {
        expect(
          () => FullReplacementBundle.decode(bytes.sublist(0, i)),
          throwsFormatException,
          reason: 'prefix length $i',
        );
      }
    });

    final headerMutations = <String, void Function(Uint8List)>{
      'wrong magic': (b) => b[0] ^= 1,
      'unsupported version': (b) => _put32(b, 8, 2),
      'big-endian version': (b) => _put32(b, 8, 0x01000000),
      'manifest over limit': (b) =>
          _put32(b, 12, fullReplacementMaxManifest + 1),
      'empty manifest': (b) => _put32(b, 12, 0),
      'empty component': (b) => _put32(b, 16, 0),
      'component over limit': (b) =>
          _put32(b, 16, fullReplacementMaxComponent + 1),
      'nonzero 64-bit component length high word': (b) => _put32(b, 20, 1),
      'incorrect length': (b) => _put32(b, 16, _component.length + 1),
      'unsupported policy': (b) => _put32(b, 24, 2),
      'component digest mismatch': (b) => b[24 + 68] ^= 1,
      'corrupt component': (b) => b[b.length - 1] ^= 1,
    };
    for (final entry in headerMutations.entries) {
      test('rejects ${entry.key}', () {
        final bytes = base64Decode(_sdkFixture);
        entry.value(bytes);
        expect(
          () => FullReplacementBundle.decode(bytes),
          throwsFormatException,
        );
      });
    }

    test('rejects trailing wrapper and manifest bytes', () {
      expect(
        () => FullReplacementBundle.decode([..._wire(), 0]),
        throwsFormatException,
      );
      expect(
        () => FullReplacementBundle.decode(_wire(manifestTail: [0])),
        throwsFormatException,
      );
    });

    test('checks bounds before copying an oversized input', () {
      expect(
        () => FullReplacementBundle.decode(
          _SizedBytes(
            24 + fullReplacementMaxManifest + fullReplacementMaxComponent + 1,
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => FullReplacementBundle(
          manifest: _base().manifest,
          component: _SizedBytes(fullReplacementMaxComponent + 1),
        ),
        throwsFormatException,
      );
    });

    test('rejects non-byte values instead of silently truncating them', () {
      final bytes = _wire().toList()..[0] += 256;
      expect(() => FullReplacementBundle.decode(bytes), throwsFormatException);
      expect(
        () => FullReplacementBundle.decode(_wire().toList()..[0] = -1),
        throwsFormatException,
      );
    });

    for (final component in [
      <int>[],
      [0x33, 0x43, 0x42],
      utf8.encode('DBC3'),
      [0x33, 0x43, 0x42, 0x45],
    ]) {
      test('rejects non-DBC3 component $component even with matching hash', () {
        expect(
          () => FullReplacementBundle.decode(_wire(component: component)),
          throwsFormatException,
        );
      });
    }

    test('owns immutable copies of all validated data', () {
      final bytes = _wire();
      final bundle = FullReplacementBundle.decode(bytes);
      final encoded = bundle.encode();
      bytes.fillRange(0, bytes.length, 0);
      expect(bundle.encode(), encoded);
      expect(() => bundle.component[0] = 0, throwsUnsupportedError);
      expect(() => bundle.manifest.hostAbi[0] = 0, throwsUnsupportedError);
      expect(
        () => bundle.manifest.baselineDigest[0] = 0,
        throwsUnsupportedError,
      );
      expect(
        () => bundle.manifest.currentDigest[0] = 0,
        throwsUnsupportedError,
      );
      expect(
        () => bundle.manifest.currentUris.add(_old),
        throwsUnsupportedError,
      );
    });

    test('rebases the same component after additions and removals', () {
      final update = _update();
      final projection = update.asBaseline();
      expect(projection.component, update.component);
      expect(projection.manifest.isBaseline, isTrue);
      expect(projection.manifest.hostAbi, update.manifest.hostAbi);
      expect(projection.manifest.rootUri, _root);
      expect(projection.manifest.baselineUris, [_root, _new]);
      expect(projection.manifest.currentUris, [_root, _new]);
      expect(projection.manifest.removedUris, isEmpty);
      expect(projection.manifest.baselineDigest, update.manifest.currentDigest);
      expect(projection.manifest.currentDigest, update.manifest.currentDigest);
      expect(
        FullReplacementBundle.decode(projection.encode()).encode(),
        projection.encode(),
      );
      expect(
        () => update.validateUpdateAgainst(projection),
        throwsFormatException,
      );
      expect(_base().asBaseline().encode(), _base().encode());
    });

    test('requires the released wrapper itself to be a baseline', () {
      expect(
        () => _update().validateUpdateAgainst(_update()),
        throwsFormatException,
      );
    });

    test('binds host ABI, base digest, root and exact baseline domain', () {
      final mismatches = [
        _update(host: List.filled(32, 1)),
        _update(baseDigest: List.filled(32, 1)),
        _update(root: _old, current: [_old], removed: [_root]),
        _update(base: [_root, _new, _old], removed: [_old]),
      ];
      for (final update in mismatches) {
        expect(
          () => update.validateUpdateAgainst(_base()),
          throwsFormatException,
        );
      }
    });

    test('isBaseline requires digest and domain equality and no removals', () {
      expect(_base().manifest.isBaseline, isTrue);
      expect(
        _update(current: [_root, _old], removed: []).manifest.isBaseline,
        isFalse,
      );
      expect(
        _update(
          baseDigest: sha256.convert(_component).bytes,
        ).manifest.isBaseline,
        isFalse,
      );
    });
  });

  group('replacement manifest', () {
    final invalidUris = <String, List<int>>{
      'empty': [],
      'NUL': [0],
      'embedded NUL': [97, 0, 98],
      'overlong UTF-8': [0xc0, 0xaf],
      'truncated UTF-8': [0xe2, 0x82],
      'surrogate UTF-8': [0xed, 0xa0, 0x80],
      'out-of-range UTF-8': [0xf4, 0x90, 0x80, 0x80],
      'overlong URI': List.filled(fullReplacementMaxUri + 1, 97),
    };
    for (final entry in invalidUris.entries) {
      test('rejects ${entry.key} in root and URI sets', () {
        expect(
          () => FullReplacementBundle.decode(_wire(root: entry.value)),
          throwsFormatException,
        );
        expect(
          () => FullReplacementBundle.decode(_wire(base: [entry.value])),
          throwsFormatException,
        );
      });
    }

    test('accepts a maximum length URI', () {
      final root = List.filled(fullReplacementMaxUri, 97);
      expect(
        FullReplacementBundle.decode(
          _wire(root: root, base: [root], current: [root], removed: []),
        ),
        isA<FullReplacementBundle>(),
      );
    });

    test('requires strict UTF-8 byte ordering rather than UTF-16 ordering', () {
      const low = 'package:app/\ue000.dart';
      const high = 'package:app/\u{10000}.dart';
      final sorted = [_root, low, high].map(utf8.encode).toList();
      expect(
        FullReplacementBundle.decode(
          _wire(base: sorted, current: sorted, removed: []),
        ),
        isA<FullReplacementBundle>(),
      );
      final unsorted = [_root, high, low].map(utf8.encode).toList();
      expect(
        () => FullReplacementBundle.decode(
          _wire(base: unsorted, current: sorted, removed: []),
        ),
        throwsFormatException,
      );
    });

    test('rejects duplicate, unordered and dart: library entries', () {
      for (final values in [
        [_root, _root],
        [_old, _root],
        ['dart:core', _root],
      ]) {
        expect(
          () => FullReplacementBundle.decode(
            _wire(base: values.map(utf8.encode).toList()),
          ),
          throwsFormatException,
        );
      }
      expect(
        () =>
            FullReplacementBundle.decode(_wire(root: utf8.encode('dart:core'))),
        throwsFormatException,
      );
    });

    test('requires root in both B and U', () {
      expect(
        () => FullReplacementBundle.decode(_wire(base: [utf8.encode(_old)])),
        throwsFormatException,
      );
      expect(
        () => FullReplacementBundle.decode(_wire(current: [utf8.encode(_new)])),
        throwsFormatException,
      );
      expect(
        () => FullReplacementBundle.decode(_wire(base: [])),
        throwsFormatException,
      );
    });

    test('requires R to equal B minus U exactly', () {
      for (final removed in [
        <String>[],
        [_new],
        [_root, _old],
        [_old, _old],
      ]) {
        expect(
          () => FullReplacementBundle.decode(
            _wire(removed: removed.map(utf8.encode).toList()),
          ),
          throwsFormatException,
        );
      }
    });

    test('rejects excessive and impossible URI counts', () {
      final bytes = _wire();
      final countOffset = 24 + 104 + utf8.encode(_root).length;
      for (final count in [fullReplacementMaxUris + 1, 65536, 0xffffffff]) {
        final changed = Uint8List.fromList(bytes);
        _put32(changed, countOffset, count);
        expect(
          () => FullReplacementBundle.decode(changed),
          throwsFormatException,
        );
      }
    });

    test('constructor rejects invalid digests and unpaired UTF-16', () {
      expect(() => _update(host: [0]), throwsFormatException);
      expect(() => _update(host: List.filled(32, 256)), throwsFormatException);
      expect(() => _update(root: '\ud800'), throwsFormatException);
    });

    test('constructor bounds total manifest size', () {
      final uris = List.generate(
        260,
        (i) => 'package:${i.toString().padLeft(4, '0')}${'a' * 16360}',
      );
      expect(
        () => _update(root: uris.first, base: uris, current: uris, removed: []),
        throwsFormatException,
      );
    });
  });
}

FullReplacementBundle _base() => _update(
  component: _baseComponent,
  current: [_root, _old],
  removed: [],
);

FullReplacementBundle _update({
  List<int>? host,
  List<int>? baseDigest,
  String root = _root,
  List<String> base = const [_root, _old],
  List<String> current = const [_root, _new],
  List<String> removed = const [_old],
  List<int> component = _component,
}) => FullReplacementBundle(
  manifest: FullReplacementManifest(
    hostAbi: host ?? List.generate(32, (i) => i),
    baselineDigest: baseDigest ?? sha256.convert(_baseComponent).bytes,
    currentDigest: sha256.convert(component).bytes,
    rootUri: root,
    baselineUris: base,
    currentUris: current,
    removedUris: removed,
  ),
  component: component,
);

// Intentionally permits malformed fields, independently of the production
// encoder, so decoder validation cannot be bypassed by constructor validation.
Uint8List _wire({
  List<int>? root,
  List<List<int>>? base,
  List<List<int>>? current,
  List<List<int>>? removed,
  List<int> component = _component,
  List<int> manifestTail = const [],
}) {
  final metadata = BytesBuilder();
  void u32(int value) => metadata.add(_u32(value));
  void uri(List<int> bytes) {
    u32(bytes.length);
    metadata.add(bytes);
  }

  u32(1);
  metadata
    ..add(List.generate(32, (i) => i))
    ..add(sha256.convert(_baseComponent).bytes)
    ..add(sha256.convert(component).bytes);
  uri(root ?? utf8.encode(_root));
  for (final set in [
    base ?? [_root, _old].map(utf8.encode).toList(),
    current ?? [_root, _new].map(utf8.encode).toList(),
    removed ?? [_old].map(utf8.encode).toList(),
  ]) {
    u32(set.length);
    set.forEach(uri);
  }
  metadata.add(manifestTail);
  final manifest = metadata.takeBytes();
  return (BytesBuilder()
        ..add(utf8.encode('SBRPLCE\u0000'))
        ..add(_u32(1))
        ..add(_u32(manifest.length))
        ..add(_u32(component.length))
        ..add(_u32(0))
        ..add(manifest)
        ..add(component))
      .takeBytes();
}

Uint8List _u32(int value) =>
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List();

void _put32(Uint8List bytes, int offset, int value) =>
    ByteData.sublistView(bytes).setUint32(offset, value, Endian.little);

class _SizedBytes extends ListBase<int> {
  _SizedBytes(this.length);

  @override
  int length;

  @override
  int operator [](int index) => throw StateError('Must reject before reading.');

  @override
  void operator []=(int index, int value) =>
      throw UnsupportedError('read only');
}
