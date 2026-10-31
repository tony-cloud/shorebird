import 'dart:typed_data';

import 'package:shorebird_cli/src/platform/apple/macho.dart';
import 'package:test/test.dart';

import 'macho_fixture.dart';

void main() {
  for (final wide in [false, true]) {
    for (final endian in [Endian.big, Endian.little]) {
      test('normalizes exact UUID for thin wide=$wide endian=$endian', () {
        final a = image(wide: wide, endian: endian);
        final b = image(wide: wide, endian: endian, uuid: 2);
        expect(MachO.normalizedUUIDBytes(a), MachO.normalizedUUIDBytes(b));
        b[b.length - 1]++;
        expect(
          MachO.normalizedUUIDBytes(a),
          isNot(MachO.normalizedUUIDBytes(b)),
        );
      });
      test('normalizes universal wide=$wide endian=$endian', () {
        final a = universal(image(), wide: wide, endian: endian);
        final b = universal(image(uuid: 2), wide: wide, endian: endian);
        expect(MachO.normalizedUUIDBytes(a), MachO.normalizedUUIDBytes(b));
        b[b.length - 1]++;
        expect(
          MachO.normalizedUUIDBytes(a),
          isNot(MachO.normalizedUUIDBytes(b)),
        );
      });
    }
  }
  for (final wide in [false, true]) {
    test('visits every universal slice wide=$wide', () {
      final a = universal(image(), wide: wide, secondSlice: image());
      final same = universal(
        image(uuid: 2),
        wide: wide,
        secondSlice: image(uuid: 3),
      );
      expect(MachO.normalizedUUIDBytes(a), MachO.normalizedUUIDBytes(same));
      final changed = universal(
        image(),
        wide: wide,
        secondSlice: image()..last = 7,
      );
      expect(
        MachO.normalizedUUIDBytes(a),
        isNot(MachO.normalizedUUIDBytes(changed)),
      );
      final overlap = Uint8List.fromList(a);
      final data = ByteData.sublistView(overlap);
      if (wide) {
        data.setUint64(48, 128);
      } else {
        data.setUint32(36, 128);
      }
      expect(() => MachO.normalizedUUIDBytes(overlap), throwsFormatException);
    });
  }
  test('debug classification requires every slice to be MH_DSYM', () {
    final debug = image();
    ByteData.sublistView(debug).setUint32(12, 0xa, Endian.little);
    expect(MachO.isDebugSymbols(debug), isTrue);
    expect(MachO.isDebugSymbols(universal(debug, secondSlice: debug)), isTrue);
    expect(
      MachO.isDebugSymbols(universal(debug, secondSlice: image())),
      isFalse,
    );
  });
  for (final wide in [false, true]) {
    for (final endian in [Endian.little, Endian.big]) {
      test('validates signed containment wide=$wide endian=$endian', () {
        expect(
          MachO.hasCodeSignature(signedImage(wide: wide, endian: endian)),
          isTrue,
        );
        final header = wide ? 32 : 28;
        final segmentSize = wide ? 72 : 56;
        final signature = header + segmentSize * 2;
        final mutations = <void Function(ByteData)>[
          // Signature points at bytes declared as executable text.
          (d) =>
              d.setUint32(signature + 8, header + segmentSize * 2 + 16, endian),
          // A text segment overlaps the otherwise bounded signature.
          (d) {
            if (wide) {
              d.setUint64(header + 48, d.lengthInBytes, endian);
            } else {
              d.setUint32(header + 36, d.lengthInBytes, endian);
            }
          },
          // The signature's LINKEDIT allocation lies outside the file.
          (d) {
            if (wide) {
              d.setUint64(header + segmentSize + 48, d.lengthInBytes, endian);
            } else {
              d.setUint32(header + segmentSize + 36, d.lengthInBytes, endian);
            }
          },
          // LINKEDIT must be non-executable in both protection fields.
          (d) =>
              d.setUint32(header + segmentSize + (wide ? 56 : 40), 5, endian),
          (d) =>
              d.setUint32(header + segmentSize + (wide ? 60 : 44), 5, endian),
          // Segment width and section count must match the command size.
          (d) => d.setUint32(header, wide ? 1 : 0x19, endian),
          (d) =>
              d.setUint32(header + segmentSize + (wide ? 64 : 48), 1, endian),
        ];
        for (final mutate in mutations) {
          final bytes = signedImage(wide: wide, endian: endian);
          mutate(ByteData.sublistView(bytes));
          expect(() => MachO.hasCodeSignature(bytes), throwsFormatException);
        }
      });
    }
  }
  test('short non-native data is safe to inspect', () {
    for (var i = 0; i < 4; i++) {
      expect(MachO.isMachOBytes(List.filled(i, 0)), isFalse);
    }
  });
  test(
    'rejects truncated headers, malformed command bounds and UUID sizes',
    () {
      final inputs = <Uint8List>[
        Uint8List.sublistView(image(), 0, 4),
        image()..buffer.asByteData().setUint32(36, 0, Endian.little),
        image()..buffer.asByteData().setUint32(36, 32, Endian.little),
        image()..buffer.asByteData().setUint32(20, 0xffffffff, Endian.little),
        universal(image())..buffer.asByteData().setUint32(16, 0xfffffff0),
        universal(image())..buffer.asByteData().setUint32(8, 7),
      ];
      for (final input in inputs) {
        expect(() => MachO.normalizedUUIDBytes(input), throwsFormatException);
      }
    },
  );
}
