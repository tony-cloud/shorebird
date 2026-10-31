import 'dart:typed_data';

import 'package:archive/archive_io.dart';

/// Verifies decompressed supplement bytes against validated ZIP metadata.
class ReleaseSupplementValidator {
  /// Creates a release supplement content validator.
  const ReleaseSupplementValidator();

  /// Returns this entry's bytes after checking its declared length and CRC.
  ///
  /// [header] must come from the complete validated ZIP directory. The caller
  /// must clear [entry] after writing to release its cached decompressed bytes.
  Uint8List readValidatedContent(ArchiveFile entry, ZipFileHeader header) {
    final bytes = entry.content;
    if (bytes.length != header.uncompressedSize ||
        getCrc32(bytes) != header.crc32) {
      throw FormatException(
        'Invalid release supplement ZIP content',
        header.filename,
      );
    }
    return bytes;
  }
}
