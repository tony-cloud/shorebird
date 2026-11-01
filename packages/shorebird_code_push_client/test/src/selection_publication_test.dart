import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:test/test.dart';

void main() {
  final scope = ReleaseSelectionScope(
    appId: '11111111-1111-4111-8111-111111111111',
    releaseVersion: '1.0.0+1',
    platform: 'macos',
    arch: 'aarch64',
    baseArtifactHash: '11' * 32,
    hostAbiHash: '22' * 32,
    runtimeProfile: 'interpreter-full',
  );
  test(
    'scope registration uses exact wire body and surfaces immutable conflict',
    () async {
      final client = CodePushClient(
        httpClient: MockClient((request) async {
          expect(request.method, 'PUT');
          expect(
            request.url.path,
            endsWith('/releases/7/selection-scopes/macos/aarch64'),
          );
          expect(jsonDecode(request.body), {
            'base_artifact_hash': '11' * 32,
            'host_abi_hash': '22' * 32,
            'runtime_profile': 'interpreter-full',
            'release_artifact_id': 101,
            'supplement_artifact_id': 102,
          });
          return http.Response(
            jsonEncode({
              'code': 'selection_scope_immutable',
              'message': 'immutable',
            }),
            409,
          );
        }),
      );
      await expectLater(
        client.registerReleaseSelectionScope(
          appId: scope.appId,
          releaseId: 7,
          scope: scope,
          releaseArtifactId: 101,
          supplementArtifactId: 102,
        ),
        throwsA(isA<CodePushConflictException>()),
      );
    },
  );
  test(
    'variant and assignment are authenticated management operations',
    () async {
      final requests = <http.Request>[];
      final client = CodePushClient(
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response('{}', 200);
        }),
      );
      final target = {
        'kind': 'base',
        'patch_number': null,
        'artifact_hash': null,
        'encryption': 'none',
        'artifact_key_id': null,
      };
      await client.putReleaseVariant(
        appId: scope.appId,
        releaseId: 7,
        variantId: 'free',
        mapping: {
          'platform': 'macos',
          'arch': 'aarch64',
          'channel': 'stable',
          'license_type': 'free',
          'target': target,
        },
      );
      final assignment = {
        'client_id': 'installation',
        'platform': 'macos',
        'arch': 'aarch64',
        'channel': 'stable',
        'variant_id': 'free',
        'entitlement_revision': 'grant-1',
        'not_before': '0',
        'offline_valid_until': null,
        'expected_epoch': '0',
        'idempotency_key': '11111111-1111-4111-8111-111111111111',
      };
      await client.assignReleaseSelection(
        appId: scope.appId,
        releaseId: 7,
        assignment: assignment,
      );
      expect(requests[0].method, 'PUT');
      expect(requests[0].url.path, endsWith('/variants/free'));
      expect(requests[1].method, 'POST');
      expect(requests[1].url.path, endsWith('/selections'));
      expect(jsonDecode(requests[1].body), assignment);
    },
  );
  test('artifact upload preserves authenticated fractional expiry', () async {
    final temp = Directory.systemTemp.createTempSync('selection-upload-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final file = File('${temp.path}/patch')
      ..writeAsStringSync('encrypted envelope transport');
    const expiry = '2030-01-01T00:00:00.123456Z';
    final client = CodePushClient(
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/artifacts')) {
          expect(request.body, contains('name="offline_expires_at"'));
          expect(request.body, contains(expiry));
          return http.Response(
            jsonEncode({
              'id': 1,
              'patch_id': 1,
              'arch': 'aarch64',
              'platform': 'macos',
              'hash': '33' * 32,
              'size': file.lengthSync(),
              'url': 'https://upload.example/patch',
            }),
            200,
          );
        }
        return http.Response('', 200);
      }),
    );
    await client.createPatchArtifact(
      artifactPath: file.path,
      appId: scope.appId,
      patchId: 1,
      arch: 'aarch64',
      platform: ReleasePlatform.macos,
      hash: '33' * 32,
      offlineExpiresAt: expiry,
    );
  });
}
