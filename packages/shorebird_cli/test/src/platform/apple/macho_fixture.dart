import 'dart:typed_data';

Uint8List image({
  bool wide = true,
  Endian endian = Endian.little,
  int uuid = 1,
}) {
  final header = wide ? 32 : 28;
  final bytes = Uint8List(header + 24 + 8);
  final data = ByteData.sublistView(bytes)
    ..setUint32(0, wide ? 0xfeedfacf : 0xfeedface, endian)
    ..setUint32(4, 0x100000c, endian)
    ..setUint32(8, 0, endian)
    ..setUint32(12, 2, endian)
    ..setUint32(16, 1, endian)
    ..setUint32(20, 24, endian)
    ..setUint32(header, 0x1b, endian)
    ..setUint32(header + 4, 24, endian);
  bytes.fillRange(header + 8, header + 24, uuid);
  data.setUint32(header + 24, 42, endian);
  return bytes;
}

Uint8List universal(
  Uint8List slice, {
  bool wide = false,
  Endian endian = Endian.big,
  Uint8List? secondSlice,
}) {
  const firstOffset = 128;
  final secondOffset = firstOffset + slice.length;
  final result = Uint8List(secondOffset + (secondSlice?.length ?? 0));
  final data = ByteData.sublistView(result)
    ..setUint32(0, wide ? 0xcafebabf : 0xcafebabe, endian)
    ..setUint32(4, secondSlice == null ? 1 : 2, endian);
  void record(int start, int cpu, int offset, int length) {
    data
      ..setUint32(start, cpu, endian)
      ..setUint32(start + 4, 0, endian);
    if (wide) {
      data
        ..setUint64(start + 8, offset, endian)
        ..setUint64(start + 16, length, endian);
    } else {
      data
        ..setUint32(start + 8, offset, endian)
        ..setUint32(start + 12, length, endian);
    }
  }

  record(8, 0x100000c, firstOffset, slice.length);
  result.setRange(firstOffset, secondOffset, slice);
  if (secondSlice != null) {
    record(8 + (wide ? 32 : 20), 0x1000007, secondOffset, secondSlice.length);
    result.setRange(secondOffset, result.length, secondSlice);
    // Test second slices use the little-endian 64-bit image builder.
    data.setUint32(secondOffset + 4, 0x1000007, Endian.little);
  }
  return result;
}

/// A bounded signed-image layout, with text and non-executable LINKEDIT.
Uint8List signedImage({bool wide = true, Endian endian = Endian.little}) {
  final header = wide ? 32 : 28;
  final segmentSize = wide ? 72 : 56;
  final commandBytes = segmentSize * 2 + 16;
  final linkeditOffset = header + commandBytes + 64;
  final bytes = Uint8List(linkeditOffset + 64);
  final data = ByteData.sublistView(bytes)
    ..setUint32(0, wide ? 0xfeedfacf : 0xfeedface, endian)
    ..setUint32(4, 0x100000c, endian)
    ..setUint32(12, 2, endian)
    ..setUint32(16, 3, endian)
    ..setUint32(20, commandBytes, endian);
  void segment(int offset, String name, int start, int size, int protection) {
    data
      ..setUint32(offset, wide ? 0x19 : 1, endian)
      ..setUint32(offset + 4, segmentSize, endian);
    bytes.setRange(offset + 8, offset + 8 + name.length, name.codeUnits);
    if (wide) {
      data
        ..setUint64(offset + 32, size, endian)
        ..setUint64(offset + 40, start, endian)
        ..setUint64(offset + 48, size, endian);
    } else {
      data
        ..setUint32(offset + 28, size, endian)
        ..setUint32(offset + 32, start, endian)
        ..setUint32(offset + 36, size, endian);
    }
    data
      ..setUint32(offset + (wide ? 56 : 40), protection, endian)
      ..setUint32(offset + (wide ? 60 : 44), protection, endian);
  }

  segment(header, '__TEXT', 0, linkeditOffset, 5);
  segment(header + segmentSize, '__LINKEDIT', linkeditOffset, 64, 1);
  final signature = header + segmentSize * 2;
  data
    ..setUint32(signature, 0x1d, endian)
    ..setUint32(signature + 4, 16, endian)
    ..setUint32(signature + 8, bytes.length - 16, endian)
    ..setUint32(signature + 12, 16, endian);
  return bytes;
}
