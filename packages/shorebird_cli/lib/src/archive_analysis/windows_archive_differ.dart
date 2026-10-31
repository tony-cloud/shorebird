import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/archive_analysis/archive_differ.dart';
import 'package:shorebird_cli/src/archive_analysis/file_set_diff.dart';

/// {@template windows_archive_differ}
/// Finds differences between two Windows app packages.
/// {@endtemplate}
class WindowsArchiveDiffer extends ArchiveDiffer {
  /// {@macro windows_archive_differ}
  const WindowsArchiveDiffer();

  String _archivePath(String path) => path.replaceAll(r'\', '/');

  bool _isDirectoryPath(String path) => _archivePath(path).endsWith('/');

  @override
  bool isAssetFilePath(String filePath) {
    // Empty directories do not affect the patch.
    return !_isDirectoryPath(filePath) &&
        p.posix.split(_archivePath(filePath)).contains('flutter_assets');
  }

  @override
  bool isDartFilePath(String filePath) {
    return p.posix.basename(_archivePath(filePath)) == 'app.so';
  }

  @override
  bool isNativeFilePath(String filePath) {
    final extension = p.posix.extension(_archivePath(filePath)).toLowerCase();
    return !_isDirectoryPath(filePath) &&
        (extension == '.exe' || extension == '.dll');
  }

  @override
  Future<PathHashes> fileHashes(File archive) async {
    return Isolate.run(() {
      final input = InputFileStream(archive.path);
      try {
        // Keep the directory entries: ZipDecoder coalesces duplicate names.
        final directory = ZipDirectory()..read(input);
        if (directory.filePosition < 0 ||
            directory.numberOfThisDisk != 0 ||
            directory.diskWithTheStartOfTheCentralDirectory != 0 ||
            directory.fileHeaders.length !=
                directory.totalCentralDirectoryEntries ||
            directory.totalCentralDirectoryEntriesOnThisDisk !=
                directory.totalCentralDirectoryEntries) {
          throw const FormatException('Invalid Windows ZIP directory');
        }
        final hashes = <String, String>{};
        final nativePaths = <String>{};
        for (final header in directory.fileHeaders) {
          // Extraction uses the local name. A nonnative central name must not
          // hide a native local entry from the checks below.
          final localName = header.file?.filename;
          if (localName != null &&
              localName != header.filename &&
              (isNativeFilePath(localName) ||
                  isNativeFilePath(header.filename))) {
            throw FormatException(
              'Inconsistent native Windows ZIP filename',
              header.filename,
            );
          }
          if (!isNativeFilePath(header.filename)) {
            // Preserve the existing checksum behavior for Dart and assets.
            hashes[header.filename] = header.crc32.toString();
            continue;
          }
          final identity = p.posix
              .normalize(_archivePath(header.filename))
              .toLowerCase();
          if (!nativePaths.add(identity)) {
            throw FormatException(
              'Duplicate native Windows ZIP entry',
              header.filename,
            );
          }
          _validateNativeEntry(input, directory, header);
          // Hash every native entry, even when its declared CRC is unchanged.
          // Only one decompressed entry is retained at a time.
          final content = header.file!.getStream();
          try {
            if (content.length != header.uncompressedSize) {
              throw FormatException(
                'Invalid native Windows ZIP entry length',
                header.filename,
              );
            }
            hashes[header.filename] = sha256
                .convert(content.toUint8List())
                .toString();
          } finally {
            content.closeSync();
          }
        }
        return hashes;
      } finally {
        input.closeSync();
      }
    });
  }

  void _validateNativeEntry(
    InputFileStream input,
    ZipDirectory directory,
    ZipFileHeader header,
  ) {
    Never invalid() => throw FormatException(
      'Invalid or unsupported native Windows ZIP entry',
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
