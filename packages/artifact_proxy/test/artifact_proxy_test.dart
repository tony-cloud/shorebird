import 'dart:io';

import 'package:artifact_proxy/artifact_proxy.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

class _MockArtifactManifestClient extends Mock
    implements ArtifactManifestClient {}

void main() {
  const shorebirdEngineRevision = '8b89f8bd9fc6982aa9c4557fd0e5e89db1ff9986';
  const manifest = ArtifactsManifest(
    flutterEngineRevision: 'ec975089acb540fc60752606a3d3ba809dd1528b',
    storageBucket: 'shorebird',
    artifactOverrides: {
      r'flutter_infra_release/flutter/$engine/dart-sdk-linux-x64.zip',
      r'flutter_infra_release/flutter/$engine/dart-sdk-darwin-arm64.zip',
      r'flutter_infra_release/flutter/$engine/android-arm64-release/artifacts.zip',
      r'flutter_infra_release/flutter/$engine/android-arm64-release/symbols.zip',
      r'flutter_infra_release/flutter/$engine/linux-x64-release/artifacts.zip',
      r'flutter_infra_release/flutter/$engine/linux-x64-release/linux-x64-flutter-gtk.zip',
      r'flutter_infra_release/flutter/$engine/ios-release/artifacts.zip',
      r'flutter_infra_release/flutter/$engine/flutter_patched_sdk_product.zip',
      r'flutter_infra_release/flutter/$engine/flutter-web-sdk.zip',
      r'flutter_infra_release/flutter/$engine/darwin-arm64-release/FlutterMacOS.framework.zip',
      r'flutter_infra_release/flutter/$engine/android-arm-release/artifacts.zip',
      r'flutter_infra_release/flutter/$engine/android-arm-release/symbols.zip',
      r'flutter_infra_release/flutter/$engine/android-x64-release/artifacts.zip',
      r'flutter_infra_release/flutter/$engine/android-x64-release/symbols.zip',
      r'download.flutter.io/io/flutter/flutter_embedding_release/1.0.0-$engine/flutter_embedding_release-1.0.0-$engine.pom',
      r'download.flutter.io/io/flutter/flutter_embedding_release/1.0.0-$engine/flutter_embedding_release-1.0.0-$engine.jar',
      r'download.flutter.io/io/flutter/arm64_v8a_release/1.0.0-$engine/arm64_v8a_release-1.0.0-$engine.pom',
      r'download.flutter.io/io/flutter/arm64_v8a_release/1.0.0-$engine/arm64_v8a_release-1.0.0-$engine.jar',
      r'download.flutter.io/io/flutter/armeabi_v7a_release/1.0.0-$engine/armeabi_v7a_release-1.0.0-$engine.pom',
      r'download.flutter.io/io/flutter/armeabi_v7a_release/1.0.0-$engine/armeabi_v7a_release-1.0.0-$engine.jar',
      r'download.flutter.io/io/flutter/x86_64_release/1.0.0-$engine/x86_64_release-1.0.0-$engine.pom',
      r'download.flutter.io/io/flutter/x86_64_release/1.0.0-$engine/x86_64_release-1.0.0-$engine.jar',
    },
  );

  Request buildRequest(String path) {
    return Request('GET', Uri.parse('http://localhost').replace(path: path));
  }

  Matcher isRedirectTo(String location) {
    return isA<Response>()
        .having((r) => r.statusCode, 'status code', HttpStatus.found)
        .having((r) => r.headers['location'], 'location', location);
  }

  group('artifactProxy', () {
    late ArtifactManifestClient client;
    late Handler handler;

    setUp(() {
      client = _MockArtifactManifestClient();
      handler = artifactProxyHandler(client: client);

      when(() => client.getManifest(any())).thenAnswer((_) async => manifest);
    });

    test('should return 404 when no manifest is found', () async {
      const path =
          'flutter_infra_release/flutter/$shorebirdEngineRevision/android-x64-release/artifacts.zip';
      when(() => client.getManifest(any())).thenThrow(Exception('oops'));
      final request = buildRequest(path);
      final response = await handler(request);
      expect(response.statusCode, equals(HttpStatus.notFound));
      verify(() => client.getManifest(shorebirdEngineRevision)).called(1);
    });

    test('should proxy to Flutter artifacts '
        'when no engine revision is detected', () async {
      const path =
          'flutter_infra_release/flutter/fonts/3012db47f3130e62f7cc0beabff968a33cbec8d8/fonts.zip';
      final request = buildRequest(path);
      final response = await handler(request);
      expect(response, isRedirectTo('https://storage.googleapis.com/$path'));
      verifyNever(() => client.getManifest(any()));
    });

    test('should proxy to Shorebird artifacts '
        'when an engine revision is detected with an override', () async {
      const path =
          'flutter_infra_release/flutter/$shorebirdEngineRevision/android-x64-release/artifacts.zip';
      final request = buildRequest(path);
      final response = await handler(request);
      expect(
        response,
        isRedirectTo(
          'http://localhost:8080/artifacts/${manifest.storageBucket}/$path',
        ),
      );
      verify(() => client.getManifest(shorebirdEngineRevision)).called(1);
    });

    test('should proxy CI-produced desktop artifacts with overrides', () async {
      const paths = [
        'flutter_infra_release/flutter/$shorebirdEngineRevision/dart-sdk-linux-x64.zip',
        'flutter_infra_release/flutter/$shorebirdEngineRevision/dart-sdk-darwin-arm64.zip',
        'flutter_infra_release/flutter/$shorebirdEngineRevision/linux-x64-release/artifacts.zip',
        'flutter_infra_release/flutter/$shorebirdEngineRevision/linux-x64-release/linux-x64-flutter-gtk.zip',
        'flutter_infra_release/flutter/$shorebirdEngineRevision/flutter_patched_sdk_product.zip',
        'flutter_infra_release/flutter/$shorebirdEngineRevision/darwin-arm64-release/FlutterMacOS.framework.zip',
      ];

      for (final path in paths) {
        expect(
          await handler(buildRequest(path)),
          isRedirectTo(
            'http://localhost:8080/artifacts/${manifest.storageBucket}/$path',
          ),
        );
      }
      verify(() => client.getManifest(shorebirdEngineRevision)).called(6);
    });

    test(
      'should proxy CI-produced iOS and web artifacts with overrides',
      () async {
        const artifactPrefix =
            'flutter_infra_release/flutter/$shorebirdEngineRevision';
        const paths = [
          '$artifactPrefix/ios-release/artifacts.zip',
          '$artifactPrefix/flutter-web-sdk.zip',
        ];

        for (final path in paths) {
          expect(
            await handler(buildRequest(path)),
            isRedirectTo(
              'http://localhost:8080/artifacts/${manifest.storageBucket}/$path',
            ),
          );
        }
        verify(() => client.getManifest(shorebirdEngineRevision)).called(2);
      },
    );

    test('can use custom Flutter and Shorebird artifact roots', () async {
      handler = artifactProxyHandler(
        client: client,
        flutterArtifactBaseUri: Uri.parse('https://flutter.example.com'),
        shorebirdArtifactBaseUri: Uri.parse('https://shorebird.example.com'),
      );
      const shorebirdPath =
          'flutter_infra_release/flutter/$shorebirdEngineRevision/android-x64-release/artifacts.zip';
      const flutterPath =
          'flutter_infra_release/flutter/$shorebirdEngineRevision/windows-x64/font-subset.zip';

      expect(
        await handler(buildRequest(shorebirdPath)),
        isRedirectTo(
          'https://shorebird.example.com/${manifest.storageBucket}/$shorebirdPath',
        ),
      );
      expect(
        await handler(buildRequest(flutterPath)),
        isRedirectTo(
          'https://flutter.example.com/flutter_infra_release/flutter/${manifest.flutterEngineRevision}/windows-x64/font-subset.zip',
        ),
      );
    });

    test('should proxy to Flutter artifacts '
        'when an engine revision is detected with no override', () async {
      const path =
          'flutter_infra_release/flutter/$shorebirdEngineRevision/windows-x64/font-subset.zip';
      final request = buildRequest(path);
      final response = await handler(request);
      expect(
        response,
        isRedirectTo(
          'https://storage.googleapis.com/flutter_infra_release/flutter/${manifest.flutterEngineRevision}/windows-x64/font-subset.zip',
        ),
      );
      verify(() => client.getManifest(shorebirdEngineRevision)).called(1);
    });

    test('rejects missing custom SDK and release runtime artifacts', () async {
      const missing = ArtifactsManifest(
        flutterEngineRevision: 'stock-engine',
        storageBucket: 'shorebird',
        artifactOverrides: {},
      );
      when(() => client.getManifest(any())).thenAnswer((_) async => missing);
      for (final suffix in [
        'dart-sdk-darwin-x64.zip',
        'dart-sdk-linux-x64.zip',
        'android-arm64-release/artifacts.zip',
        'ios-release/artifacts.zip',
        'darwin-arm64-release/FlutterMacOS.framework.zip',
        'windows-x64/windows-x64-flutter.zip',
      ]) {
        final response = await handler(
          buildRequest(
            'flutter_infra_release/flutter/$shorebirdEngineRevision/$suffix',
          ),
        );
        expect(response.statusCode, HttpStatus.notFound, reason: suffix);
        expect(response.headers['location'], isNull, reason: suffix);
      }
    });

    test('should return 404 '
        'when pattern is not recognized', () async {
      const path =
          'flutter_infra_release/flutter/$shorebirdEngineRevision/unknown/artifacts.zip';
      final request = buildRequest(path);
      final response = await handler(request);
      expect(response.statusCode, equals(HttpStatus.notFound));
      verifyNever(() => client.getManifest(shorebirdEngineRevision));
    });

    test('should return explainer at /', () async {
      const path = '/';
      final request = buildRequest(path);
      final response = await handler(request);
      expect(response.statusCode, equals(HttpStatus.ok));
      verifyNever(() => client.getManifest(any()));
      expect(response.headers['content-type'], equals('text/html'));
      expect(response.readAsString(), completion(contains('Shorebird')));
    });
  });
}
