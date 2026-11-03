import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The header of a `vmcode` v1 container (docs/ios-linker/COMPILER_LINKER.md
/// section 6): link table plus the patch ELF, all integers little-endian.
class VmcodeHeader {
  const VmcodeHeader._({
    required this.headerBytes,
    required this.elfOffset,
    required this.elfSize,
    required this.linkCount,
    required this.releaseTextSha256,
    required this.elfSha256,
    required this.releaseTextSize,
    required this.patchTextSize,
    required this.linkedCodeBytes,
    required this.patchCodeBytes,
  });

  /// The magic: `OSBVMC\0\x01`.
  static const magic = [0x4f, 0x53, 0x42, 0x56, 0x4d, 0x43, 0x00, 0x01];

  /// The only format version this reads.
  static const version = 1;

  /// Bytes of the fixed part of the header; the link table follows.
  static const fixedBytes = 128;

  /// Alignment of the ELF offset (the iOS page size).
  static const elfAlignment = 16384;

  /// Bytes of one link entry.
  static const linkEntryBytes = 16;

  /// Parses the header of [bytes] and checks that its geometry is
  /// self-consistent. Does not hash anything.
  static VmcodeHeader parse(Uint8List bytes) {
    if (bytes.length < fixedBytes) {
      throw const FormatException('vmcode: truncated header');
    }
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) {
        throw const FormatException('vmcode: bad magic');
      }
    }
    final d = ByteData.sublistView(bytes);
    int u32(int o) => d.getUint32(o, Endian.little);
    int u64(int o) => d.getUint64(o, Endian.little);
    if (u32(8) != version) {
      throw FormatException('vmcode: unsupported version ${u32(8)}');
    }
    final headerBytes = u32(12);
    final elfOffset = u64(16);
    final elfSize = u64(24);
    final linkCount = u32(32);
    if (u32(36) != linkEntryBytes ||
        u32(40) != fixedBytes ||
        u32(44) != 0 ||
        headerBytes != elfOffset ||
        elfOffset % elfAlignment != 0 ||
        fixedBytes + linkCount * linkEntryBytes > elfOffset ||
        elfOffset + elfSize != bytes.length) {
      throw const FormatException('vmcode: inconsistent header geometry');
    }
    final linkedCodeBytes = u32(120);
    final patchCodeBytes = u32(124);
    if (linkedCodeBytes > patchCodeBytes) {
      throw const FormatException('vmcode: linked bytes exceed code bytes');
    }
    return VmcodeHeader._(
      headerBytes: headerBytes,
      elfOffset: elfOffset,
      elfSize: elfSize,
      linkCount: linkCount,
      releaseTextSha256: _hex(bytes.sublist(48, 80)),
      elfSha256: _hex(bytes.sublist(80, 112)),
      releaseTextSize: u32(112),
      patchTextSize: u32(116),
      linkedCodeBytes: linkedCodeBytes,
      patchCodeBytes: patchCodeBytes,
    );
  }

  /// Reads and parses [file], and checks that the embedded ELF hashes to the
  /// header's value.
  static VmcodeHeader readVerified(File file) {
    final bytes = file.readAsBytesSync();
    final header = parse(bytes);
    final actual = sha256
        .convert(
          Uint8List.sublistView(
            bytes,
            header.elfOffset,
            header.elfOffset + header.elfSize,
          ),
        )
        .toString();
    if (actual != header.elfSha256) {
      throw const FormatException('vmcode: embedded ELF hash mismatch');
    }
    return header;
  }

  /// Header size; equal to [elfOffset].
  final int headerBytes;

  /// Where the patch ELF starts in the container.
  final int elfOffset;

  /// Bytes of the patch ELF.
  final int elfSize;

  /// Number of link entries.
  final int linkCount;

  /// SHA-256 of the release `_kDartSnapshotText` the patch links to.
  final String releaseTextSha256;

  /// SHA-256 of the embedded ELF.
  final String elfSha256;

  /// Bytes of the release text image.
  final int releaseTextSize;

  /// Bytes of the patch text image.
  final int patchTextSize;

  /// Code bytes that run natively from the release.
  final int linkedCodeBytes;

  /// Code bytes of the patch.
  final int patchCodeBytes;

  /// Linked code bytes over patch code bytes, in percent.
  double get linkPercent =>
      patchCodeBytes == 0 ? 100 : linkedCodeBytes * 100 / patchCodeBytes;

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
