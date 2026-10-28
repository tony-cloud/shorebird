// print is used for diagnostic logs.
// ignore_for_file: avoid_print

import 'package:artifact_proxy/artifact_proxy.dart';
import 'package:artifact_proxy/config.dart';
import 'package:shelf/shelf.dart';

const String _explainerHtml = """
<html>
<head>
<title>Shorebird Artifact Proxy</title>
</head>
<body>
<p>
This server proxies requests for Flutter artifacts to the correct location,
	depending on the engine revision. Most artifacts are served from the configured
	Flutter artifact origin, but a few artifacts are served from the configured
	open Shorebird artifact mirror to add support for code push.
</p>
<p>
See the workspace README and docs/CI.md for open artifact mirror details.
</p>
<p>
Source code can be found here:
<a
	href='https://github.com/tony-cloud/shorebird'>
	https://github.com/tony-cloud/shorebird</a>
</p>
<p>
If you're seeing problems with this open artifact proxy, file an issue against
the repository that hosts this workspace.
</p>
</body>
</html>
""";

/// A [Handler] that proxies artifact requests to the correct location.
Handler artifactProxyHandler({
  required ArtifactManifestClient client,
  Uri? flutterArtifactBaseUri,
  Uri? shorebirdArtifactBaseUri,
}) {
  final flutterBaseUri =
      flutterArtifactBaseUri ?? defaultFlutterArtifactBaseUri;
  final shorebirdBaseUri =
      shorebirdArtifactBaseUri ?? defaultShorebirdArtifactBaseUri;

  return (Request request) async {
    final path = request.url.path;
    if (path.isEmpty) {
      return Response.ok(
        _explainerHtml,
        headers: {'content-type': 'text/html'},
      );
    }

    RegExpMatch? engineArtifactMatch;
    for (final pattern in engineArtifactPatterns) {
      final match = RegExp(pattern).firstMatch(path);
      if (match != null && match.group(1) != null) {
        engineArtifactMatch = match;
        break;
      }
    }

    if (engineArtifactMatch != null) {
      final shorebirdEngineRevision = engineArtifactMatch.group(1)!;
      final ArtifactsManifest manifest;
      try {
        manifest = await client.getManifest(shorebirdEngineRevision);
      } on Exception catch (error) {
        return Response.notFound(
          'Failed to fetch manifest for $shorebirdEngineRevision\n$error',
        );
      }

      final normalizedPath = path.replaceAll(
        shorebirdEngineRevision,
        r'$engine',
      );

      final shouldOverride = manifest.artifactOverrides.contains(
        normalizedPath,
      );

      if (shouldOverride) {
        final location = getShorebirdArtifactLocation(
          artifactPath: normalizedPath,
          engine: shorebirdEngineRevision,
          bucket: manifest.storageBucket,
          baseUri: shorebirdBaseUri,
        );
        print('Shorebird engine artifact detected, forwarding to: $location');
        return Response.found(location);
      }

      // A stock SDK, kernel tool, or release engine is incompatible with our
      // custom VM. Missing artifacts must fail without silent substitution.
      if (_requiresCustomSdkArtifact(normalizedPath)) {
        return Response.notFound(
          'No custom SDK or runtime artifact is published for $normalizedPath. '
          'Build and publish this target before using code push.',
        );
      }

      final location = getFlutterArtifactLocation(
        artifactPath: normalizedPath,
        engine: manifest.flutterEngineRevision,
        baseUri: flutterBaseUri,
      );
      print('Flutter artifact detected, forwarding to: $location');
      return Response.found(location);
    }

    final isRecognizedFlutterArtifact = flutterArtifactPatterns.any(
      (pattern) => RegExp(pattern).hasMatch(path),
    );

    if (!isRecognizedFlutterArtifact) {
      return Response.notFound('Unrecognized artifact path: $path');
    }

    final location = getFlutterArtifactLocation(
      artifactPath: path,
      baseUri: flutterBaseUri,
    );
    print('Flutter artifact detected, forwarding to: $location');
    return Response.found(location);
  };
}

/// Default public Flutter artifact origin.
final defaultFlutterArtifactBaseUri = Uri.parse(
  'https://storage.googleapis.com',
);

/// Default root for open self-hosted Shorebird artifacts.
final defaultShorebirdArtifactBaseUri = Uri.parse(
  'http://localhost:8080/artifacts',
);

/// Returns the location of the artifact at [artifactPath] using the
/// specified [engine] revision for original Flutter artifacts.
String getFlutterArtifactLocation({
  required String artifactPath,
  String? engine,
  Uri? baseUri,
}) {
  final adjustedPath = engine != null
      ? artifactPath.replaceAll(r'$engine', engine)
      : artifactPath;

  return _joinUri(
    baseUri ?? defaultFlutterArtifactBaseUri,
    adjustedPath,
  ).toString();
}

/// Returns the location of the artifact at [artifactPath] using the
/// specified [engine] revision for Shorebird artifacts.
String getShorebirdArtifactLocation({
  required String artifactPath,
  required String engine,
  required String bucket,
  Uri? baseUri,
}) {
  final adjustedPath = artifactPath.replaceAll(r'$engine', engine);
  final bucketUri = Uri.tryParse(bucket);
  final resolvedBaseUri = bucketUri != null && bucketUri.hasScheme
      ? bucketUri
      : baseUri ?? defaultShorebirdArtifactBaseUri;
  final path = bucketUri != null && bucketUri.hasScheme
      ? adjustedPath
      : [if (bucket.isNotEmpty) bucket, adjustedPath].join('/');
  return _joinUri(resolvedBaseUri, path).toString();
}

Uri _joinUri(Uri base, String path) {
  final basePath = base.path.endsWith('/')
      ? base.path.substring(0, base.path.length - 1)
      : base.path;
  final relativePath = path.startsWith('/') ? path.substring(1) : path;
  return base.replace(path: '$basePath/$relativePath');
}

/// Runtime binaries and kernel tools must match the custom VM revision.
/// font-subset.zip includes const_finder.dart.snapshot, which reads kernels.
/// Static font assets and debug-only artifacts may still use upstream files.
bool _requiresCustomSdkArtifact(String path) {
  return RegExp(r'/dart-sdk-[^/]+\.zip$').hasMatch(path) ||
      path.endsWith('/font-subset.zip') ||
      path.endsWith('/flutter_patched_sdk_product.zip') ||
      RegExp(
        '/(?:android-[^/]+|ios|darwin(?:-[^/]+)?|linux-[^/]+)-release/',
      ).hasMatch(path) ||
      RegExp(r'/windows-[^/]+/windows-[^/]+-flutter\.zip$').hasMatch(path) ||
      RegExp('/io/flutter/[^/]+_release/').hasMatch(path);
}
