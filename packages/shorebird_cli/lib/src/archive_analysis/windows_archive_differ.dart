import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/archive_analysis/archive_differ.dart';
import 'package:shorebird_cli/src/archive_analysis/file_set_diff.dart';
import 'package:shorebird_cli/src/archive_analysis/portable_zip_namespace_validator.dart';

/// {@template windows_archive_differ}
/// Finds differences between two Windows app packages.
/// {@endtemplate}
class WindowsArchiveDiffer extends ArchiveDiffer {
  /// {@macro windows_archive_differ}
  const WindowsArchiveDiffer();

  String _archivePath(String path) => path.replaceAll(r'\', '/');

  bool _isDirectoryPath(String path) => _archivePath(path).endsWith('/');

  bool _isNativeAssetsManifestPath(String path) =>
      p.posix.normalize(_archivePath(path)).toUpperCase() ==
      'DATA/FLUTTER_ASSETS/NATIVEASSETSMANIFEST.JSON';

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

  /// Rejects unsafe or ambiguous Windows ZIP records before extraction.
  Future<void> validateArchive(File archive) async {
    return Isolate.run(() {
      final input = InputFileStream(archive.path);
      try {
        const PortableZipNamespaceValidator(
          'Windows',
        ).readValidatedDirectory(input);
      } finally {
        input.closeSync();
      }
    });
  }

  @override
  Future<PathHashes> fileHashes(File archive) async {
    return Isolate.run(() {
      final input = InputFileStream(archive.path);
      try {
        final directory = const PortableZipNamespaceValidator(
          'Windows',
        ).readValidatedDirectory(input);
        final hashes = <String, String>{};
        for (final header in directory.fileHeaders) {
          if (!isNativeFilePath(header.filename)) {
            // Preserve the existing checksum behavior for Dart and assets.
            hashes[header.filename] = header.crc32.toString();
            continue;
          }
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
