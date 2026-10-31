import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/archive_analysis/archive_differ.dart';
import 'package:shorebird_cli/src/archive_analysis/file_set_diff.dart';
import 'package:shorebird_cli/src/archive_analysis/native_zip_validator.dart';

/// {@template windows_archive_differ}
/// Finds differences between two Windows app packages.
/// {@endtemplate}
class WindowsArchiveDiffer extends ArchiveDiffer {
  /// {@macro windows_archive_differ}
  const WindowsArchiveDiffer();

  String _archivePath(String path) => path.replaceAll(r'\', '/');

  bool _isDirectoryPath(String path) => _archivePath(path).endsWith('/');

  bool _isNativeAssetsManifestPath(String path) =>
      p.posix.normalize(_archivePath(path)).toLowerCase() ==
      'data/flutter_assets/nativeassetsmanifest.json';

  @override
  bool isAssetFilePath(String filePath) {
    // Empty directories do not affect the patch.
    return !_isDirectoryPath(filePath) &&
        !_isNativeAssetsManifestPath(filePath) &&
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
        (extension == '.exe' ||
            extension == '.dll' ||
            _isNativeAssetsManifestPath(filePath));
  }

  @override
  Future<PathHashes> fileHashes(File archive) async {
    return Isolate.run(() {
      final input = InputFileStream(archive.path);
      try {
        // Keep the directory entries: ZipDecoder coalesces duplicate names.
        const validator = NativeZipValidator('Windows');
        final directory = validator.readDirectory(input);
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
          validator.validateEntry(input, directory, header);
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
}
