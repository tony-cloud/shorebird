import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dex/dex.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/archive_analysis/archive_differ.dart';
import 'package:shorebird_cli/src/archive_analysis/bundle_dependencies.dart';
import 'package:shorebird_cli/src/archive_analysis/file_set_diff.dart';
import 'package:shorebird_cli/src/archive_analysis/native_zip_validator.dart';

/// A [FileSetDiff] that also carries semantic DEX diff results.
class AndroidFileSetDiff extends FileSetDiff {
  /// Creates an [AndroidFileSetDiff] with DEX diff results.
  const AndroidFileSetDiff({
    required super.addedPaths,
    required super.removedPaths,
    required super.changedPaths,
    this.dexDiffResults = const {},
    this.dependencyVersionChanges = const [],
  });

  /// DEX diff results for breaking changes, keyed by file path.
  final Map<String, DexDiffResult> dexDiffResults;

  /// Maven libraries whose resolved versions differ between the two bundles.
  ///
  /// Only computed when DEX files have breaking changes, since a dependency
  /// version change is the most common cause of DEX changes the developer
  /// didn't make. Empty if neither bundle carries dependency metadata.
  final List<DependencyVersionChange> dependencyVersionChanges;
}

/// {@template android_archive_differ}
/// Finds differences between two Android archives (either AABs or AARs).
///
/// Types of changes we care about:
///   - Dart code changes
///      - libapp.so will be different
///   - Java/Kotlin code changes
///      - .dex, .jar, or .class files will be different
///   - Engine and plugin native code changes
///      - Other .so files will be different
///   - Assets
///      - **/assets/** will be different
///      - AssetManifest.json will have changed if assets have been added or
///        removed
///
/// Changes we don't care about:
///   - Signature and manifest records in META-INF
///   - BUNDLE-METADATA/com.android.tools.build.libraries/dependencies.pb
///      - This seems to change with every build, regardless of whether any code
///        or assets were changed. When DEX files change, the Maven versions it
///        records are compared to explain why (see
///        [AndroidFileSetDiff.dependencyVersionChanges]).
///
/// See https://developer.android.com/guide/app-bundle/app-bundle-format and
/// https://developer.android.com/studio/projects/android-library
/// for reference. Flutter module AARs also contain classes.jar; patches do not
/// deliver Java bytecode or native libraries other than the Dart snapshot.
/// {@endtemplate}
class AndroidArchiveDiffer extends ArchiveDiffer {
  /// {@macro android_archive_differ}
  const AndroidArchiveDiffer();

  @override
  Future<PathHashes> fileHashes(File archive) async {
    return Isolate.run(() {
      final input = InputFileStream(archive.path);
      try {
        const validator = NativeZipValidator('Android');
        final directory = validator.readDirectory(input);
        final identities = <String, int>{};
        final filePaths = <String>{};
        for (final header in directory.fileHeaders) {
          final path = header.filename;
          final identity = path.endsWith('/')
              ? path.substring(0, path.length - 1)
              : path;
          identities.update(identity, (count) => count + 1, ifAbsent: () => 1);
          if (!path.endsWith('/')) filePaths.add(path);
        }
        final hashes = <String, String>{};
        for (final header in directory.fileHeaders) {
          final path = header.filename;
          // Android package extraction must not redirect through a link,
          // including a directory or asset alias hiding a native ancestor.
          if (((header.externalFileAttributes >> 16) & 0xf000) == 0xa000) {
            throw FormatException('Symbolic links in Android ZIP', path);
          }
          final localName = header.file?.filename;
          if (localName != null &&
              localName != path &&
              (_requiresNativeValidation(localName) ||
                  _requiresNativeValidation(path))) {
            throw FormatException(
              'Inconsistent Android code ZIP filename',
              path,
            );
          }
          if (!_requiresNativeValidation(path)) {
            // Preserve asset and metadata comparison behavior.
            hashes[path] = header.crc32.toString();
            continue;
          }
          if (p.posix.isAbsolute(path) ||
              path.contains(r'\') ||
              path.contains('\x00') ||
              path
                  .split('/')
                  .any(
                    (part) => part.isEmpty || part == '.' || part == '..',
                  ) ||
              identities[path] != 1) {
            throw FormatException('Ambiguous Android code ZIP path', path);
          }
          var parent = p.posix.dirname(path);
          while (parent != '.') {
            if (filePaths.contains(parent)) {
              throw FormatException(
                'Android ZIP file used as a directory',
                path,
              );
            }
            parent = p.posix.dirname(parent);
          }
          validator.validateEntry(input, directory, header);
          final content = header.file!.getStream();
          try {
            if (content.length != header.uncompressedSize) {
              throw FormatException(
                'Invalid Android code ZIP entry length',
                path,
              );
            }
            // CRC32 is not an identity: different engine/plugin/DEX bytes can
            // have the same valid ZIP checksum. Hash the actual code payload.
            hashes[path] = sha256.convert(content.toUint8List()).toString();
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

  @override
  Future<AndroidFileSetDiff> changedFiles(
    String oldArchivePath,
    String newArchivePath,
  ) async {
    final fileSetDiff = await super.changedFiles(
      oldArchivePath,
      newArchivePath,
    );

    final dexPaths = fileSetDiff.changedPaths
        .where((p) => p.endsWith('.dex'))
        .toList();

    if (dexPaths.isEmpty) {
      return AndroidFileSetDiff(
        addedPaths: fileSetDiff.addedPaths,
        removedPaths: fileSetDiff.removedPaths,
        changedPaths: fileSetDiff.changedPaths,
      );
    }

    // Extract DEX file bytes (and dependency metadata) from both archives.
    final oldFiles = _extractFiles(oldArchivePath, [
      ...dexPaths,
      bundleDependenciesPath,
    ]);
    final newFiles = _extractFiles(newArchivePath, [
      ...dexPaths,
      bundleDependenciesPath,
    ]);

    const parser = DexParser();
    const differ = DexDiffer();
    final safePaths = <String>{};
    final dexDiffResults = <String, DexDiffResult>{};

    for (final path in dexPaths) {
      final oldBytes = oldFiles[path];
      final newBytes = newFiles[path];
      if (oldBytes == null || newBytes == null) continue;

      try {
        final oldDex = parser.parse(oldBytes);
        final newDex = parser.parse(newBytes);
        final result = differ.diff(oldDex, newDex);

        if (result.isSafe) {
          safePaths.add(path);
        } else {
          dexDiffResults[path] = result;
        }
        // Catch all exceptions so unparseable DEX files are conservatively
        // treated as changed rather than crashing the diff.
        // ignore: avoid_catches_without_on_clauses
      } catch (_) {
        // If parsing fails, conservatively keep the path as changed.
      }
    }

    final changedPaths = fileSetDiff.changedPaths.difference(safePaths);
    final hasBreakingDexChanges = changedPaths.any((p) => p.endsWith('.dex'));

    return AndroidFileSetDiff(
      addedPaths: fileSetDiff.addedPaths,
      removedPaths: fileSetDiff.removedPaths,
      changedPaths: changedPaths,
      dexDiffResults: dexDiffResults,
      dependencyVersionChanges: hasBreakingDexChanges
          ? _dependencyVersionChanges(
              oldFiles[bundleDependenciesPath],
              newFiles[bundleDependenciesPath],
            )
          : const [],
    );
  }

  List<DependencyVersionChange> _dependencyVersionChanges(
    Uint8List? oldBytes,
    Uint8List? newBytes,
  ) {
    if (oldBytes == null || newBytes == null) return const [];
    try {
      return diffDependencyVersions(
        parseBundleDependencies(oldBytes),
        parseBundleDependencies(newBytes),
      );
    } on FormatException {
      // The metadata is only used to explain a DEX change, so a file we can't
      // parse just means no explanation.
      return const [];
    }
  }

  Map<String, Uint8List> _extractFiles(
    String archivePath,
    List<String> paths,
  ) {
    final pathSet = paths.toSet();
    final result = <String, Uint8List>{};
    final input = InputFileStream(archivePath);
    try {
      final archive = ZipDecoder().decodeStream(input);
      for (final file in archive.files) {
        if (file.isFile && pathSet.contains(file.name)) {
          result[file.name] = Uint8List.fromList(file.content);
        }
      }
    } finally {
      input.closeSync();
    }
    return result;
  }

  @override
  bool isAssetFilePath(String filePath) {
    if (_isNativeAssetsManifestPath(filePath)) return false;
    const assetDirNames = ['assets', 'res'];
    const assetFileNames = ['AssetManifest.json'];

    return p
            .split(filePath)
            .any((component) => assetDirNames.contains(component)) ||
        assetFileNames.contains(p.basename(filePath));
  }

  @override
  bool isDartFilePath(String filePath) {
    // These are the only Dart libraries extracted and delivered by the Android
    // patchers. Feature modules, assets, and unsupported ABIs remain native.
    return RegExp(
      r'^(?:base/lib|lib|jni)/(?:armeabi-v7a|arm64-v8a|x86_64)/libapp\.so$',
    ).hasMatch(filePath);
  }

  @override
  bool isNativeFilePath(String filePath) =>
      _requiresNativeValidation(filePath) && !isDartFilePath(filePath);

  // Normalize only to recognize aliases of the frozen root lookup map; the
  // native ZIP checks above reject ambiguous separators and path components.
  bool _isNativeAssetsManifestPath(String path) => const {
    'base/assets/flutter_assets/NativeAssetsManifest.json',
    'assets/flutter_assets/NativeAssetsManifest.json',
  }.contains(p.posix.normalize(path.replaceAll(r'\', '/')));

  bool _requiresNativeValidation(String filePath) =>
      _isNativeAssetsManifestPath(filePath) ||
      (!filePath.endsWith('/') &&
          const {'.dex', '.so', '.jar', '.class'}.contains(
            p.posix.extension(filePath).toLowerCase(),
          ));
}
