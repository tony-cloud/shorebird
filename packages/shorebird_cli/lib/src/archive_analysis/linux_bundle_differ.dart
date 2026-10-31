import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/archive_analysis/archive_differ.dart';
import 'package:shorebird_cli/src/archive_analysis/file_set_diff.dart';
import 'package:shorebird_cli/src/archive_analysis/native_zip_validator.dart';

/// {@template linux_bundle_differ}
/// Finds differences between two Linux bundles.
/// {@endtemplate}
class LinuxBundleDiffer extends ArchiveDiffer {
  /// {@macro linux_bundle_differ}
  const LinuxBundleDiffer();

  bool _isDirectoryPath(String path) => path.endsWith('/');

  @override
  bool isAssetFilePath(String filePath) =>
      !_isDirectoryPath(filePath) &&
      p.posix.split(filePath).contains('flutter_assets');

  @override
  bool isDartFilePath(String filePath) => filePath == 'lib/libapp.so';

  @override
  bool isNativeFilePath(String filePath) {
    // Runners and executable assets are also identified by ELF content and
    // Unix executable permissions when reading the ZIP, regardless of name.
    return !_isDirectoryPath(filePath) &&
        !isDartFilePath(filePath) &&
        RegExp(r'\.so(?:\.[^/]+)?$').hasMatch(filePath);
  }

  @override
  FileSetDiff nativeFileSetDiff(FileSetDiff fileSetDiff) {
    if (fileSetDiff is _LinuxFileSetDiff) {
      return fileSetDiff.where(fileSetDiff.nativePaths.contains);
    }
    return super.nativeFileSetDiff(fileSetDiff);
  }

  @override
  Future<FileSetDiff> changedFiles(
    String oldArchivePath,
    String newArchivePath,
  ) async {
    final oldArchive = await _analyzeArchive(File(oldArchivePath));
    final newArchive = await _analyzeArchive(File(newArchivePath));
    return _LinuxFileSetDiff(
      FileSetDiff.fromPathHashes(
        oldPathHashes: oldArchive.hashes,
        newPathHashes: newArchive.hashes,
      ),
      {...oldArchive.nativePaths, ...newArchive.nativePaths},
    );
  }

  @override
  Future<PathHashes> fileHashes(File archive) async =>
      (await _analyzeArchive(archive)).hashes;

  Future<_LinuxArchiveAnalysis> _analyzeArchive(File archive) async {
    return Isolate.run(() {
      final input = InputFileStream(archive.path);
      try {
        const validator = NativeZipValidator('Linux');
        final directory = validator.readDirectory(input);
        final paths = <String, bool>{};
        // Check the complete namespace before inspecting content. Duplicate
        // assets or a file replacing a parent directory can also conceal code.
        for (final header in directory.fileHeaders) {
          final path = header.filename;
          final isDirectory = _isDirectoryPath(path);
          final identity = isDirectory
              ? path.substring(0, path.length - 1)
              : path;
          if (identity.isEmpty ||
              p.posix.isAbsolute(path) ||
              path.contains(r'\') ||
              path.contains('\x00') ||
              identity
                  .split('/')
                  .any(
                    (part) => part.isEmpty || part == '.' || part == '..',
                  ) ||
              paths.containsKey(identity)) {
            throw FormatException('Ambiguous Linux ZIP path', path);
          }
          paths[identity] = isDirectory;
          // Extraction uses local names, including for entries that otherwise
          // look like ordinary assets or the patchable Dart library.
          validator.validateEntry(input, directory, header);
        }
        for (final path in paths.keys) {
          var parent = p.posix.dirname(path);
          while (parent != '.') {
            if (paths[parent] == false) {
              throw FormatException('Linux ZIP file used as a directory', path);
            }
            parent = p.posix.dirname(parent);
          }
        }
        final hashes = <String, String>{};
        final nativePaths = <String>{};
        for (final header in directory.fileHeaders) {
          final path = header.filename;
          if (_isDirectoryPath(path) || isDartFilePath(path)) {
            hashes[path] = header.crc32.toString();
            continue;
          }
          // Inspect each file: executable native assets need not have a shared
          // library suffix or Unix permissions in an archive from another host.
          final content = header.file!.getStream();
          try {
            if (content.length != header.uncompressedSize) {
              throw FormatException('Invalid Linux ZIP entry length', path);
            }
            final bytes = content.toUint8List();
            final isElf =
                bytes.length >= 4 &&
                bytes[0] == 0x7f &&
                bytes[1] == 0x45 &&
                bytes[2] == 0x4c &&
                bytes[3] == 0x46;
            final mode = header.externalFileAttributes >> 16;
            // ZipFileEncoder stores full stat.mode even though ZipEncoder sets
            // a DOS creator. Other non-Unix permission metadata stays unknown.
            final hasUnixMode =
                header.versionMadeBy >> 8 == 3 || mode & 0xf000 == 0x8000;
            final executeBits = hasUnixMode ? mode & 0x49 : null;
            final isExecutable = executeBits != null && executeBits != 0;
            if (isNativeFilePath(path) || isElf || isExecutable) {
              nativePaths.add(path);
              final executeState = executeBits?.toRadixString(8) ?? 'unknown';
              hashes[path] = '${sha256.convert(bytes)}:unix-exec=$executeState';
            } else {
              hashes[path] = header.crc32.toString();
            }
          } finally {
            content.closeSync();
          }
        }
        return _LinuxArchiveAnalysis(hashes, nativePaths);
      } finally {
        input.closeSync();
      }
    });
  }
}

class _LinuxArchiveAnalysis {
  const _LinuxArchiveAnalysis(this.hashes, this.nativePaths);

  final PathHashes hashes;
  final Set<String> nativePaths;
}

class _LinuxFileSetDiff extends FileSetDiff {
  _LinuxFileSetDiff(FileSetDiff diff, this.nativePaths)
    : super(
        addedPaths: diff.addedPaths,
        removedPaths: diff.removedPaths,
        changedPaths: diff.changedPaths,
      );

  final Set<String> nativePaths;

  @override
  FileSetDiff where(bool Function(String path) test) => _LinuxFileSetDiff(
    super.where(test),
    nativePaths.where(test).toSet(),
  );
}
