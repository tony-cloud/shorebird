import 'package:archive/archive_io.dart';

/// Validates ZIP records before their bytes are used for native comparisons.
class NativeZipValidator {
  /// Creates a validator for diagnostic messages for [platform].
  const NativeZipValidator(this.platform);

  /// Platform name used in validation errors.
  final String platform;

  /// Reads every central directory entry without coalescing duplicate names.
  ZipDirectory readDirectory(InputFileStream input) {
    final directory = ZipDirectory()..read(input);
    if (directory.filePosition < 0 ||
        directory.numberOfThisDisk != 0 ||
        directory.diskWithTheStartOfTheCentralDirectory != 0 ||
        directory.fileHeaders.length !=
            directory.totalCentralDirectoryEntries ||
        directory.totalCentralDirectoryEntriesOnThisDisk !=
            directory.totalCentralDirectoryEntries) {
      throw FormatException('Invalid $platform ZIP directory');
    }
    return directory;
  }

  /// Rejects unreadable, encrypted, inconsistent, or unsupported file records.
  void validateEntry(
    InputFileStream input,
    ZipDirectory directory,
    ZipFileHeader header,
  ) {
    Never invalid() => throw FormatException(
      'Invalid or unsupported $platform ZIP entry',
      header.filename,
    );

    if (header.localHeaderOffset < 0 ||
        header.localHeaderOffset + 30 > directory.centralDirectoryOffset ||
        header.diskNumberStart != 0 ||
        (header.externalFileAttributes >> 16) & 0xf000 == 0xa000 ||
        (header.generalPurposeBitFlag & 0x41) != 0 ||
        !{0, 8}.contains(header.compressionMethod)) {
      invalid();
    }
    final local = input.subset(position: header.localHeaderOffset);
    if (local.readUint32() != ZipFile.zipSignature) invalid();
    local.readUint16(); // Version needed to extract.
    final flags = local.readUint16();
    final compression = local.readUint16();
    local.readUint32(); // Modification time and date.
    final crc = local.readUint32();
    var compressedSize = local.readUint32();
    var uncompressedSize = local.readUint32();
    final nameLength = local.readUint16();
    final extraLength = local.readUint16();
    final dataOffset = header.localHeaderOffset + 30 + nameLength + extraLength;
    if (dataOffset + header.compressedSize > directory.centralDirectoryOffset ||
        flags != header.generalPurposeBitFlag ||
        compression != header.compressionMethod ||
        local.readString(size: nameLength) != header.filename) {
      invalid();
    }
    final extra = local.readBytes(extraLength);
    if (compressedSize == 0xffffffff || uncompressedSize == 0xffffffff) {
      var foundZip64 = false;
      while (extra.length >= 4) {
        final id = extra.readUint16();
        final length = extra.readUint16();
        if (length > extra.length) invalid();
        final field = extra.readBytes(length);
        if (id != 1) continue;
        if (uncompressedSize == 0xffffffff) {
          if (field.length < 8) invalid();
          uncompressedSize = field.readUint64();
        }
        if (compressedSize == 0xffffffff) {
          if (field.length < 8) invalid();
          compressedSize = field.readUint64();
        }
        foundZip64 = true;
        break;
      }
      if (!foundZip64) invalid();
    }
    final hasDescriptor = flags & 8 != 0;
    if (hasDescriptor) {
      final descriptorOffset = dataOffset + header.compressedSize;
      if (descriptorOffset + 12 > directory.centralDirectoryOffset) invalid();
      final descriptor = input.subset(position: descriptorOffset);
      final signatureOrCrc = descriptor.readUint32();
      if (signatureOrCrc == 0x08074b50 &&
          descriptorOffset + 16 > directory.centralDirectoryOffset) {
        invalid();
      }
      // The archive library reads the descriptor into these fields.
      if ((crc != 0 && crc != header.crc32) ||
          (compressedSize != 0 && compressedSize != header.compressedSize) ||
          (uncompressedSize != 0 &&
              uncompressedSize != header.uncompressedSize)) {
        invalid();
      }
    } else if (crc != header.crc32 ||
        compressedSize != header.compressedSize ||
        uncompressedSize != header.uncompressedSize) {
      invalid();
    }
    final file = header.file;
    if (file == null ||
        file.filename != header.filename ||
        file.crc32 != header.crc32 ||
        file.compressedSize != header.compressedSize ||
        file.uncompressedSize != header.uncompressedSize ||
        file.getStream(decompress: false).length != header.compressedSize) {
      invalid();
    }
  }
}
