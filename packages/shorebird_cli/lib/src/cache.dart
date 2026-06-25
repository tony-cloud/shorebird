import 'dart:ffi' show Abi;
import 'dart:io' hide Platform;

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:platform/platform.dart';
import 'package:retry/retry.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/abi.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/checksum_checker.dart';
import 'package:shorebird_cli/src/flutter_version_constraints.dart';
import 'package:shorebird_cli/src/http_client/http_client.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/shorebird_artifacts.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_flutter.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';

/// {@template cache_update_failure}
/// Thrown when a cache update fails.
/// This can occur if the artifact is unreachable or
/// if the download is interrupted.
/// {@endtemplate}
class CacheUpdateFailure implements Exception {
  /// {@macro cache_update_failure}
  const CacheUpdateFailure(this.message);

  /// The error message.
  final String message;

  @override
  String toString() => 'CacheUpdateFailure: $message';
}

/// A reference to a [Cache] instance.
final cacheRef = create(Cache.new);

/// The [Cache] instance available in the current zone.
Cache get cache => read(cacheRef);

/// {@template cache}
/// A class that manages the artifacts cached by Shorebird.
/// This class handles fetching and unpacking artifacts from various sources.
///
/// To access specific artifacts, it's generally recommended to use
/// [ShorebirdArtifacts] since uses the current Shorebird environment.
/// {@endtemplate}
class Cache {
  /// {@macro cache}
  Cache() {
    registerArtifact(PatchArtifact(cache: this, platform: platform));
    registerArtifact(BundleToolArtifact(cache: this, platform: platform));
    if (legacyAotToolsEnabled) {
      registerArtifact(AotToolsArtifact(cache: this, platform: platform));
    }
  }

  /// Environment variable that enables the legacy closed aot-tools download.
  static const legacyAotToolsEnvironmentVariable =
      'SHOREBIRD_ENABLE_LEGACY_AOT_TOOLS';

  /// Whether to download legacy `aot-tools.dill`.
  ///
  /// The open iOS App Store-safe path uses Dart bytecode interpreter artifacts
  /// and must not fetch Shorebird's closed native-AOT linker artifact by
  /// default. Developers can opt in when validating the old native-AOT route.
  bool get legacyAotToolsEnabled {
    final value = platform.environment[legacyAotToolsEnvironmentVariable]
        ?.trim()
        .toLowerCase();
    return value == '1' || value == 'true' || value == 'yes';
  }

  /// Register a new [CachedArtifact] with the cache.
  void registerArtifact(CachedArtifact artifact) => _artifacts.add(artifact);

  /// Update all artifacts in the cache.
  ///
  /// [retryDelayFactor] is the delay between retries that doubles after every
  /// attempt. The default from the retry package is 200ms. This is settable for
  /// testing.
  Future<void> updateAll([
    Duration retryDelayFactor = const Duration(milliseconds: 200),
  ]) async {
    for (final artifact in _artifacts) {
      if (await artifact.isValid()) {
        continue;
      }

      await retry(
        artifact.update,
        maxAttempts: 3,
        delayFactor: retryDelayFactor,
        onRetry: (e) {
          logger
            ..detail('Failed to update ${artifact.fileName}, retrying...')
            ..detail(e.toString());
        },
      );
    }
  }

  /// Get a named directory from with the cache's artifact directory;
  /// for example, `foo` would return `bin/cache/artifacts/foo`.
  Directory getArtifactDirectory(String name) {
    return Directory(
      p.join(shorebirdArtifactsDirectory.path, p.withoutExtension(name)),
    );
  }

  /// Get a named directory from with the cache's preview directory;
  /// for example, `foo` would return `bin/cache/previews/foo`.
  Directory getPreviewDirectory(String name) {
    return Directory(
      p.join(shorebirdPreviewsDirectory.path, p.withoutExtension(name)),
    );
  }

  /// The Shorebird cache directory.
  static Directory get shorebirdCacheDirectory {
    return Directory(p.join(shorebirdEnv.shorebirdRoot.path, 'bin', 'cache'));
  }

  /// The Shorebird cached previews directory.
  static Directory get shorebirdPreviewsDirectory {
    return Directory(p.join(shorebirdCacheDirectory.path, 'previews'));
  }

  /// The Shorebird cached artifacts directory.
  static Directory get shorebirdArtifactsDirectory {
    return Directory(p.join(shorebirdCacheDirectory.path, 'artifacts'));
  }

  final List<CachedArtifact> _artifacts = [];

  /// Default local root for open Shorebird CLI-managed binary artifacts.
  static const defaultArtifactBaseUrl = 'http://localhost:8080/artifacts';

  /// The storage base url.
  String get storageBaseUrl =>
      platform.environment['SHOREBIRD_STORAGE_BASE_URL'] ??
      defaultArtifactBaseUrl;

  /// The storage bucket host.
  String get storageBucket =>
      platform.environment['SHOREBIRD_STORAGE_BUCKET'] ?? '';

  /// The root URL for Shorebird CLI-managed binary artifacts.
  ///
  /// Defaults to a local open artifact mirror. Deployments can set
  /// `SHOREBIRD_ARTIFACT_BASE_URL` to host the same `/shorebird/<engine
  /// revision>/...` layout at a public URL.
  String get artifactBaseUrl {
    final override = platform.environment['SHOREBIRD_ARTIFACT_BASE_URL'];
    if (override != null && override.trim().isNotEmpty) {
      return _trimTrailingSlash(override.trim());
    }

    final bucket = storageBucket.trim();
    final base = _trimTrailingSlash(storageBaseUrl.trim());
    if (bucket.isEmpty) return base;
    return '$base/${_trimSlashes(bucket)}';
  }

  /// Clear the cache.
  Future<void> clear() async {
    final cacheDir = shorebirdCacheDirectory;
    if (cacheDir.existsSync()) {
      await cacheDir.delete(recursive: true);
    }
  }

  /// Returns the full URL for a Shorebird artifact stored under the current
  /// engine revision.
  String shorebirdArtifactUrl(String fileName) {
    return '$artifactBaseUrl/shorebird/${shorebirdEnv.shorebirdEngineRevision}/$fileName';
  }

  String _trimTrailingSlash(String value) {
    var trimmed = value;
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }

  String _trimSlashes(String value) {
    var trimmed = value;
    while (trimmed.startsWith('/')) {
      trimmed = trimmed.substring(1);
    }
    return _trimTrailingSlash(trimmed);
  }
}

/// {@template cached_artifact}
/// An artifact which is cached by Shorebird.
/// {@endtemplate}
abstract class CachedArtifact {
  /// {@macro cached_artifact}
  CachedArtifact({required this.cache, required this.platform});

  /// The cache instance to use.
  final Cache cache;

  /// The platform to use.
  final Platform platform;

  /// The on-disk name of the artifact.
  String get fileName;

  /// Should the artifact be marked executable.
  bool get isExecutable;

  /// The URL from which the artifact can be downloaded. Returned as a
  /// future so subclasses can resolve runtime context (e.g. the active
  /// Flutter version) before deciding which artifact to fetch.
  Future<String> get storageUrl;

  /// Whether the artifact is required for Shorebird to function.
  /// If we fail to fetch it we will exit with an error.
  bool get required => true;

  /// The SHA256 checksum of the artifact binary.
  ///
  /// When null, the checksum is not verified and the downloaded artifact
  /// is assumed to be correct.
  String? get checksum;

  /// Extract the artifact from the provided [stream] to the [outputPath].
  Future<void> extractArtifact(http.ByteStream stream, String outputPath) {
    final file = File(p.join(outputPath, fileName))
      ..createSync(recursive: true);
    return stream.pipe(file.openWrite());
  }

  /// The artifact file on disk.
  File get file =>
      File(p.join(cache.getArtifactDirectory(fileName).path, fileName));

  /// Used to validate that the artifact was fully downloaded and extracted.
  File get stampFile => File('${file.path}.stamp');

  /// Whether the artifact is valid (has a matching checksum).
  Future<bool> isValid() async {
    if (!file.existsSync() || !stampFile.existsSync()) {
      return false;
    }

    if (checksum == null) {
      logger.detail(
        '''No checksum provided for $fileName, skipping file corruption validation''',
      );
      return true;
    }

    return checksumChecker.checkFile(file, checksum!);
  }

  /// Re-fetch the artifact from the storage URL.
  Future<void> update() async {
    // Clear any existing artifact files.
    await _delete();

    final updateProgress = logger.progress('Downloading $fileName...');

    final url = await storageUrl;
    final request = http.Request('GET', Uri.parse(url));
    final http.StreamedResponse response;
    try {
      response = await httpClient.send(request);
    } catch (error) {
      throw CacheUpdateFailure('''
Failed to download $fileName: $error
If you're behind a firewall/proxy, please, make sure shorebird_cli is
allowed to access $url.''');
    }

    if (response.statusCode != HttpStatus.ok) {
      if (!required && response.statusCode == HttpStatus.notFound) {
        logger.detail(
          '[cache] optional artifact: "$fileName" was not found, skipping...',
        );
        return;
      }

      updateProgress.fail();
      throw CacheUpdateFailure(
        '''Failed to download $fileName: ${response.statusCode} ${response.reasonPhrase}''',
      );
    }

    updateProgress.complete();

    final extractProgress = logger.progress('Extracting $fileName...');
    final artifactDirectory = Directory(p.dirname(file.path));
    try {
      await extractArtifact(response.stream, artifactDirectory.path);
    } catch (_) {
      extractProgress.fail();
      rethrow;
    }

    final expectedChecksum = checksum;
    if (expectedChecksum != null) {
      if (!checksumChecker.checkFile(file, expectedChecksum)) {
        extractProgress.fail();
        // Delete the artifact directory, so if the download is retried, it will
        // be re-downloaded.
        artifactDirectory.deleteSync(recursive: true);
        throw CacheUpdateFailure(
          '''Failed to download $fileName: checksum mismatch''',
        );
      } else {
        logger.detail(
          '''No checksum provided for $fileName, skipping file corruption validation''',
        );
      }
    }

    if (!platform.isWindows && isExecutable) {
      final result = await process.start('chmod', ['+x', file.path]);
      await result.exitCode;
    }

    extractProgress.complete();
    _writeStampFile();
  }

  // Writes a 0-byte file to indicate that the artifact was successfully
  // installed.
  void _writeStampFile() {
    stampFile.createSync(recursive: true);
  }

  Future<void> _delete() async {
    if (file.existsSync()) {
      await file.delete();
    }

    if (stampFile.existsSync()) {
      await stampFile.delete();
    }
  }
}

/// {@template aot_tools_artifact}
/// The legacy closed aot_tools.dill artifact.
///
/// This is not part of the default open-source cache. It is available only
/// when [Cache.legacyAotToolsEnvironmentVariable] is set for development-only
/// native-AOT validation.
/// {@endtemplate}
class AotToolsArtifact extends CachedArtifact {
  /// {@macro aot_tools_artifact}
  AotToolsArtifact({required super.cache, required super.platform});

  @override
  String get fileName => 'aot-tools.dill';

  @override
  bool get isExecutable => false;

  /// The aot-tools are only available for revisions that support mixed-mode.
  @override
  bool get required => false;

  @override
  File get file => File(
    p.join(
      cache.getArtifactDirectory(fileName).path,
      shorebirdEnv.shorebirdEngineRevision,
      fileName,
    ),
  );

  @override
  Future<String> get storageUrl async => cache.shorebirdArtifactUrl(fileName);

  @override
  String? get checksum => null;
}

/// {@template patch_artifact}
/// The patch artifact which is used to apply binary patches.
/// {@endtemplate}
class PatchArtifact extends CachedArtifact {
  /// {@macro patch_artifact}
  PatchArtifact({required super.cache, required super.platform});

  @override
  String get fileName => platform.isWindows ? 'patch.exe' : 'patch';

  @override
  bool get isExecutable => true;

  @override
  Future<void> extractArtifact(
    http.ByteStream stream,
    String outputPath,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync();
    final artifactPath = p.join(tempDir.path, '$fileName.zip');
    await stream.pipe(File(artifactPath).openWrite());
    await artifactManager.extractZip(
      zipFile: File(artifactPath),
      outputDirectory: Directory(outputPath),
    );
  }

  @override
  Future<String> get storageUrl async {
    var artifactName = 'patch-';
    if (platform.isMacOS) {
      final useArm64 =
          abi.current == Abi.macosArm64 && await _supportsArm64Patch();
      artifactName += useArm64 ? 'darwin-arm64.zip' : 'darwin-x64.zip';
    } else if (platform.isLinux) {
      artifactName += 'linux-x64.zip';
    } else if (platform.isWindows) {
      artifactName += 'windows-x64.zip';
    }

    return cache.shorebirdArtifactUrl(artifactName);
  }

  Future<bool> _supportsArm64Patch() async {
    final revision = shorebirdEnv.flutterRevision;
    final version = await shorebirdFlutter.resolveFlutterVersion(revision);
    return arm64PatchSupportConstraint.isSatisfiedBy(
      version: version ?? arm64PatchSupportConstraint.minVersion,
      revision: revision,
    );
  }

  @override
  String? get checksum => null;
}

/// {@template bundle_tool_artifact}
/// The bundletool.jar artifact.
/// Used for interacting with Android app bundles (aab).
/// {@endtemplate}
class BundleToolArtifact extends CachedArtifact {
  /// {@macro bundle_tool_artifact}
  BundleToolArtifact({required super.cache, required super.platform});

  @override
  String get fileName => 'bundletool.jar';

  @override
  bool get isExecutable => false;

  @override
  Future<String> get storageUrl async {
    return 'https://github.com/google/bundletool/releases/download/1.18.1/bundletool-all-1.18.1.jar';
  }

  @override
  String? get checksum =>
      // SHA-256 checksum of the bundletool.jar file.
      // When updating the bundletool version, be sure to update this checksum.
      // This can be done by running the following command:
      // ```shell
      // shasum --algorithm 256 /path/to/file
      // ```
      '''675786493983787ffa11550bdb7c0715679a44e1643f3ff980a529e9c822595c''';
}
