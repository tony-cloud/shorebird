import 'dart:io';

import 'package:artifact_proxy/artifact_proxy.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_hotreload/shelf_hotreload.dart';

Future<void> main(List<String> args) async {
  final isDev = Platform.environment['DEV'] == 'true';
  final shorebirdArtifactBaseUri = _uriFromEnvironment(
    'SHOREBIRD_ARTIFACT_BASE_URL',
    ArtifactManifestClient.defaultManifestBaseUri,
  );
  final flutterArtifactBaseUri = _uriFromEnvironment(
    'ARTIFACT_PROXY_FLUTTER_BASE_URL',
    defaultFlutterArtifactBaseUri,
  );
  final port = int.parse(Platform.environment['PORT'] ?? '8080');

  if (args.contains('--health-check')) {
    stdout.writeln(
      'artifact_proxy ok '
      'shorebird_artifacts=$shorebirdArtifactBaseUri '
      'flutter_artifacts=$flutterArtifactBaseUri '
      'port=$port',
    );
    return;
  }

  final client = ArtifactManifestClient(
    manifestBaseUri: shorebirdArtifactBaseUri,
  );
  final handler = artifactProxyHandler(
    client: client,
    flutterArtifactBaseUri: flutterArtifactBaseUri,
    shorebirdArtifactBaseUri: shorebirdArtifactBaseUri,
  );
  final ip = InternetAddress.anyIPv6;

  // Hot-reload is enabled when the DEBUG environment variable is set to true.
  if (isDev) return withHotreload(() => serve(handler, ip, port));

  await serve(handler, ip, port);
}

Future<HttpServer> serve(Handler proxy, InternetAddress ip, int port) async {
  const pipeline = Pipeline();
  final handler = pipeline.addMiddleware(logRequests()).addHandler(proxy);
  final server = await shelf_io.serve(handler, ip, port);
  server.autoCompress = true;
  return server;
}

Uri _uriFromEnvironment(String name, Uri defaultValue) {
  final value = Platform.environment[name];
  if (value == null || value.trim().isEmpty) return defaultValue;
  return Uri.parse(value.trim());
}
