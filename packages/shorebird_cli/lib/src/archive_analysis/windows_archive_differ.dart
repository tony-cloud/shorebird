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
        _readValidatedDirectory(input);
      } finally {
        input.closeSync();
      }
    });
  }

  ZipDirectory _readValidatedDirectory(InputFileStream input) {
    const validator = NativeZipValidator('Windows');
    // Keep every directory record: ZipDecoder coalesces duplicate names.
    final directory = validator.readDirectory(input);
    final paths = <String, bool>{};
    for (final header in directory.fileHeaders) {
      final path = _archivePath(header.filename);
      final isDirectory = path.endsWith('/');
      // Conservatively merge Unicode case aliases as well as ASCII names.
      // This is a namespace guard, not an emulation of NTFS normalization.
      final identity = isDirectory
          ? path.substring(0, path.length - 1).toUpperCase()
          : path.toUpperCase();
      if (identity.isEmpty ||
          identity.split('/').any((part) => !_isSafeWindowsComponent(part)) ||
          paths.containsKey(identity)) {
        throw FormatException(
          'Unsafe or duplicate Windows ZIP path',
          header.filename,
        );
      }
      paths[identity] = isDirectory;
      // A nonnative local name or ancestor can also change the namespace.
      validator.validateEntry(input, directory, header);
      final type = (header.externalFileAttributes >> 16) & 0xf000;
      final attributes = header.externalFileAttributes & 0xffff;
      // DOS volume labels, devices and Windows reparse points are not files.
      final hasSpecialAttributes = attributes & 0x448 != 0;
      if (!{0, 0x8000, 0x4000}.contains(type) ||
          (type == 0x4000 && !isDirectory) ||
          (type == 0x8000 && isDirectory) ||
          (attributes & 0x10 != 0 && !isDirectory) ||
          hasSpecialAttributes ||
          (isDirectory && header.uncompressedSize != 0)) {
        throw FormatException(
          'Unsupported Windows ZIP file type',
          header.filename,
        );
      }
    }
    for (final path in paths.keys) {
      var parent = p.posix.dirname(path);
      while (parent != '.') {
        if (paths[parent] == false) {
          throw FormatException('Windows ZIP file used as a directory', path);
        }
        parent = p.posix.dirname(parent);
      }
    }
    return directory;
  }

  bool _isSafeWindowsComponent(String part) {
    if (part.isEmpty ||
        part == '.' ||
        part == '..' ||
        part.endsWith('.') ||
        part.endsWith(' ') ||
        RegExp(r'[\x00-\x1f<>:"|?*]').hasMatch(part)) {
      return false;
    }
    // Device names remain reserved with an extension (for example, NUL.txt).
    final stem = part
        .split('.')
        .first
        .replaceFirst(RegExp(r' +$'), '')
        .toLowerCase();
    return !RegExp(
      r'^(con|prn|aux|nul|conin\$|conout\$|clock\$|com[1-9¹²³]|lpt[1-9¹²³])$',
    ).hasMatch(stem);
  }

  @override
  Future<PathHashes> fileHashes(File archive) async {
    return Isolate.run(() {
      final input = InputFileStream(archive.path);
      try {
        final directory = _readValidatedDirectory(input);
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
