import 'dart:io';

import 'package:artifact_proxy/artifact_proxy.dart';
import 'package:checked_yaml/checked_yaml.dart';
import 'package:http/http.dart' as http;
import 'package:quiver/collection.dart';

/// {@template artifact_manifest_client}
/// A client that fetches [ArtifactsManifest]s from an open artifact mirror and
/// caches them in memory.
/// {@endtemplate}
class ArtifactManifestClient {
  /// {@macro artifact_manifest_client}
  ArtifactManifestClient({http.Client? httpClient, Uri? manifestBaseUri})
    : _httpClient = httpClient ?? http.Client(),
      _manifestBaseUri = manifestBaseUri ?? defaultManifestBaseUri;

  /// Default root for open self-hosted artifact manifests.
  static final defaultManifestBaseUri = Uri.parse(
    'http://localhost:8080/artifacts',
  );

  final http.Client _httpClient;
  final Uri _manifestBaseUri;

  final _cache = LruMap<String, ArtifactsManifest>(maximumSize: 1000);

  /// Fetches the [ArtifactsManifest] for the provided [revision].
  Future<ArtifactsManifest> getManifest(String revision) async {
    if (_cache.containsKey(revision)) return _cache[revision]!;
    final manifest = await _fetchManifest(revision);
    _cache[revision] = manifest;
    return manifest;
  }

  Future<ArtifactsManifest> _fetchManifest(String revision) async {
    final url = _joinUri(
      _manifestBaseUri,
      'shorebird/$revision/artifacts_manifest.yaml',
    );
    final response = await _httpClient.get(url);
    if (response.statusCode != HttpStatus.ok) {
      throw Exception('''
Failed to fetch artifacts manifest for revision $revision.
${response.statusCode} ${response.reasonPhrase}''');
    }

    return checkedYamlDecode(
      response.body,
      (m) => ArtifactsManifest.fromJson(m!),
    );
  }
}

Uri _joinUri(Uri base, String path) {
  final basePath = base.path.endsWith('/')
      ? base.path.substring(0, base.path.length - 1)
      : base.path;
  final relativePath = path.startsWith('/') ? path.substring(1) : path;
  return base.replace(path: '$basePath/$relativePath');
}
