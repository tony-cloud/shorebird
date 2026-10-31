import 'dart:io';
import 'dart:typed_data';

/// Bounds-checked utilities for thin and universal Mach-O images.
/// Layouts follow the Xcode SDK's mach-o/loader.h and mach-o/fat.h.
class MachO {
  static const _thinMagic = {0xfeedface, 0xfeedfacf, 0xcefaedfe, 0xcffaedfe};
  static const _fatMagic = {0xcafebabe, 0xcafebabf, 0xbebafeca, 0xbfbafeca};

  /// Whether [bytes] starts with a recognized thin or universal magic.
  static bool isMachOBytes(List<int> bytes) {
    if (bytes.length < 4) return false;
    final magic =
        (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
    return _thinMagic.contains(magic) || _fatMagic.contains(magic);
  }

  /// Whether [file] starts with a recognized Mach-O magic.
  static bool isMachOFile(File file) => isMachOBytes(file.readAsBytesSync());

  /// Validates every image and reports whether any slice has a signature.
  static bool hasCodeSignature(List<int> bytes) {
    var signed = false;
    _visit(_view(bytes), (type, start, length) {
      if (type == 0x1d) signed = true;
    });
    return signed;
  }

  /// Whether every validated slice is a debug-symbol image (MH_DSYM).
  static bool isDebugSymbols(List<int> bytes) {
    var debugOnly = true;
    _visit(
      _view(bytes),
      (_, _, _) {},
      imageType: (type) => debugOnly = debugOnly && type == 0xa,
      validateSignatures: false,
    );
    return debugOnly;
  }

  /// Returns the image with exactly the sixteen LC_UUID bytes zeroed.
  static Uint8List bytesWithZeroedUUID(File file) =>
      normalizedUUIDBytes(file.readAsBytesSync());

  /// Validates and normalizes UUIDs in all slices without ignoring code bytes.
  static Uint8List normalizedUUIDBytes(List<int> input) {
    final bytes = Uint8List.fromList(input);
    _visit(bytes, (type, start, length) {
      if (type == 0x1b) bytes.fillRange(start + 8, start + 24, 0);
    });
    return bytes;
  }

  static Uint8List _view(List<int> bytes) =>
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

  static Never _invalid() =>
      throw const FormatException('Malformed Mach-O image');

  static void _visit(
    Uint8List bytes,
    void Function(int type, int start, int length) command, {
    void Function(int)? imageType,
    bool validateSignatures = true,
  }) {
    if (!isMachOBytes(bytes)) _invalid();
    final data = ByteData.sublistView(bytes);
    final magic = data.getUint32(0);
    if (_thinMagic.contains(magic)) {
      _thin(
        data,
        0,
        bytes.length,
        command,
        imageType: imageType,
        validateSignatures: validateSignatures,
      );
      return;
    }
    if (bytes.length < 8) _invalid();
    final endian = magic == 0xbebafeca || magic == 0xbfbafeca
        ? Endian.little
        : Endian.big;
    final wide = magic == 0xcafebabf || magic == 0xbfbafeca;
    final stride = wide ? 32 : 20;
    final count = data.getUint32(4, endian);
    if (count == 0 || count > (bytes.length - 8) ~/ stride) _invalid();
    final tableEnd = 8 + count * stride;
    final slices = <(int, int)>[];
    final architectures = <(int, int)>{};
    for (var i = 0; i < count; i++) {
      final start = 8 + i * stride;
      final cpu = data.getUint32(start, endian);
      final subtype = data.getUint32(start + 4, endian);
      final offset = wide
          ? data.getUint64(start + 8, endian)
          : data.getUint32(start + 8, endian);
      final size = wide
          ? data.getUint64(start + 16, endian)
          : data.getUint32(start + 12, endian);
      final alignment = data.getUint32(start + (wide ? 24 : 16), endian);
      if (offset < tableEnd ||
          size < 4 ||
          offset > bytes.length ||
          size > bytes.length - offset ||
          alignment > 31 ||
          offset % (1 << alignment) != 0 ||
          (wide && data.getUint32(start + 28, endian) != 0) ||
          !architectures.add((cpu, subtype))) {
        _invalid();
      }
      for (final slice in slices) {
        if (offset < slice.$2 && offset + size > slice.$1) _invalid();
      }
      slices.add((offset, offset + size));
      _thin(
        data,
        offset,
        size,
        command,
        cpu: cpu,
        subtype: subtype,
        imageType: imageType,
        validateSignatures: validateSignatures,
      );
    }
  }

  static void _thin(
    ByteData data,
    int start,
    int size,
    void Function(int, int, int) command, {
    int? cpu,
    int? subtype,
    void Function(int)? imageType,
    bool validateSignatures = true,
  }) {
    if (size < 4) _invalid();
    final magic = data.getUint32(start);
    if (!_thinMagic.contains(magic)) _invalid();
    final endian = magic == 0xcefaedfe || magic == 0xcffaedfe
        ? Endian.little
        : Endian.big;
    final wide = magic == 0xfeedfacf || magic == 0xcffaedfe;
    final headerSize = wide ? 32 : 28;
    if (size < headerSize) {
      _invalid();
    }
    if ((cpu != null && data.getUint32(start + 4, endian) != cpu) ||
        (subtype != null && data.getUint32(start + 8, endian) != subtype)) {
      _invalid();
    }
    imageType?.call(data.getUint32(start + 12, endian));
    final count = data.getUint32(start + 16, endian);
    final commandsSize = data.getUint32(start + 20, endian);
    if (commandsSize > size - headerSize || count > commandsSize ~/ 8) {
      _invalid();
    }
    final end = start + headerSize + commandsSize;
    var offset = start + headerSize;
    var uuidSeen = false;
    var signatureSeen = false;
    (int, int)? signatureRange;
    final segments = <(int, int, int)>[];
    for (var i = 0; i < count; i++) {
      if (offset + 8 > end) _invalid();
      final type = data.getUint32(offset, endian);
      final length = data.getUint32(offset + 4, endian);
      if (length < 8 || length % (wide ? 8 : 4) != 0 || length > end - offset) {
        _invalid();
      }
      if (type == 0x1 || type == 0x19) {
        segments.add((type, offset, length));
      }
      if (type == 0x1b) {
        if (length != 24 || uuidSeen) _invalid();
        uuidSeen = true;
      }
      if (type == 0x1d) {
        if (length != 16 || signatureSeen) _invalid();
        signatureSeen = true;
        final signatureOffset = data.getUint32(offset + 8, endian);
        final signatureSize = data.getUint32(offset + 12, endian);
        signatureRange = (signatureOffset, signatureOffset + signatureSize);
        if (validateSignatures &&
            (signatureOffset < headerSize + commandsSize ||
                signatureSize == 0 ||
                signatureOffset > size ||
                signatureSize > size - signatureOffset)) {
          _invalid();
        }
      }
      command(type, offset, length);
      offset += length;
    }
    if (offset != end) _invalid();
    if (signatureRange != null && validateSignatures) {
      _validateSignatureSegments(
        data,
        size,
        wide,
        endian,
        segments,
        signatureRange,
      );
    }
  }

  static void _validateSignatureSegments(
    ByteData data,
    int size,
    bool wide,
    Endian endian,
    List<(int, int, int)> commands,
    (int, int) signature,
  ) {
    final segments = <({int start, int end, bool linkedit, bool executable})>[];
    for (final command in commands) {
      final (type, offset, length) = command;
      final headerSize = wide ? 72 : 56;
      if (type != (wide ? 0x19 : 0x1) || length < headerSize) _invalid();
      final count = data.getUint32(offset + (wide ? 64 : 48), endian);
      if (length != headerSize + count * (wide ? 80 : 68)) _invalid();
      final fileOffset = wide
          ? data.getUint64(offset + 40, endian)
          : data.getUint32(offset + 32, endian);
      final fileSize = wide
          ? data.getUint64(offset + 48, endian)
          : data.getUint32(offset + 36, endian);
      if (fileOffset < 0 ||
          fileSize < 0 ||
          fileOffset > size ||
          fileSize > size - fileOffset) {
        _invalid();
      }
      const linkeditName = '__LINKEDIT';
      var linkedit = true;
      for (var i = 0; i < 16; i++) {
        final expected = i < linkeditName.length
            ? linkeditName.codeUnitAt(i)
            : 0;
        if (data.getUint8(offset + 8 + i) != expected) linkedit = false;
      }
      final maxProtection = data.getUint32(offset + (wide ? 56 : 40), endian);
      final initialProtection = data.getUint32(
        offset + (wide ? 60 : 44),
        endian,
      );
      segments.add((
        start: fileOffset,
        end: fileOffset + fileSize,
        linkedit: linkedit,
        executable: (maxProtection | initialProtection) & 4 != 0,
      ));
    }
    final linkedit = segments.where((segment) => segment.linkedit).toList();
    if (linkedit.length != 1 ||
        linkedit.single.executable ||
        signature.$1 < linkedit.single.start ||
        signature.$2 > linkedit.single.end) {
      _invalid();
    }
    for (final segment in segments.where((segment) => !segment.linkedit)) {
      if (signature.$1 < segment.end && signature.$2 > segment.start) {
        _invalid();
      }
    }
  }
}
