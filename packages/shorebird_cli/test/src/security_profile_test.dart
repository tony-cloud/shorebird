import 'dart:convert';
import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/security_profile.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:test/test.dart';

import 'helpers.dart';
import 'mocks.dart';

void main() {
  useTempWorkingDirectory();

  final hardenedId = 'sha256:${'c' * 64}';

  // A release-root pin (base64 of a canonical release-root payload).
  const releaseRoot = 'eyJjb250cmFjdF92ZXJzaW9uIjoyfQ==';

  Map<String, Object?> floor({
    String profile = 'hardened',
    Object? toolchainId = '',
    Object? developmentExceptions = false,
    int version = 2,
  }) => {
    'schema': 'open-shorebird.toolchain-security',
    'contract_version': version,
    'security_profile': profile,
    'toolchain_id': toolchainId == '' ? hardenedId : toolchainId,
    'development_exceptions': developmentExceptions,
    if (version == 2) ...{
      'release_root': profile == 'hardened' ? releaseRoot : null,
      'min_delegations_version': 1,
    },
  };

  Matcher throwsInvalid(String reason) => throwsA(
    isA<ToolchainSecurityException>().having(
      (e) => e.message,
      'message',
      allOf(contains('is invalid'), contains(reason)),
    ),
  );

  group(SecurityProfile, () {
    test('parses only the v1 profiles', () {
      expect(SecurityProfile.tryParse('legacy'), SecurityProfile.legacy);
      expect(SecurityProfile.tryParse('hardened'), SecurityProfile.hardened);
      expect(SecurityProfile.tryParse('hardened-diversified'), isNull);
      expect(SecurityProfile.tryParse('Hardened'), isNull);
    });
  });

  group(ToolchainSecurity, () {
    group('parse', () {
      test('reads a hardened toolchain', () {
        final security = ToolchainSecurity.parse(jsonEncode(floor()));
        expect(security.profile, SecurityProfile.hardened);
        expect(security.toolchainId, hardenedId);
        expect(security.developmentExceptions, isFalse);
        expect(security.releaseRoot, releaseRoot);
        expect(security.buildEnvironment, {
          'SHOREBIRD_SECURITY_PROFILE': 'hardened',
          'SHOREBIRD_TOOLCHAIN_ID': hardenedId,
          'SHOREBIRD_RELEASE_ROOT': releaseRoot,
          'SHOREBIRD_RELEASE_MIN_DELEGATIONS_VERSION': '1',
        });
      });

      test('passes a raised delegations floor to flutter build', () {
        final security = ToolchainSecurity.parse(
          jsonEncode({...floor(), 'min_delegations_version': 4}),
        );
        expect(security.minDelegationsVersion, 4);
        expect(
          security
              .buildEnvironment['SHOREBIRD_RELEASE_MIN_DELEGATIONS_VERSION'],
          '4',
        );
      });

      test('reads a contract v1 legacy toolchain unchanged', () {
        final security = ToolchainSecurity.parse(
          jsonEncode(floor(profile: 'legacy', toolchainId: null, version: 1)),
        );
        expect(security.profile, SecurityProfile.legacy);
        expect(security.releaseRoot, isNull);
        expect(security.buildEnvironment, isEmpty);
      });

      test('rejects a contract v1 hardened toolchain (no release root)', () {
        expect(
          () => ToolchainSecurity.parse(jsonEncode(floor(version: 1))),
          throwsInvalid('needs contract_version 2'),
        );
      });

      test('requires the release root for hardened and only for hardened', () {
        expect(
          () => ToolchainSecurity.parse(
            jsonEncode({...floor(), 'release_root': null}),
          ),
          throwsInvalid('needs a release_root'),
        );
        for (final bad in ['not base64!', 7]) {
          expect(
            () => ToolchainSecurity.parse(
              jsonEncode({...floor(), 'release_root': bad}),
            ),
            throwsInvalid('release_root must be'),
          );
        }
        for (final bad in [0, -1, '1', null]) {
          expect(
            () => ToolchainSecurity.parse(
              jsonEncode({...floor(), 'min_delegations_version': bad}),
            ),
            throwsInvalid('min_delegations_version must be'),
          );
        }
        for (final legacy in [
          {...floor(profile: 'legacy'), 'release_root': releaseRoot},
          {...floor(profile: 'legacy'), 'min_delegations_version': 2},
        ]) {
          expect(
            () => ToolchainSecurity.parse(jsonEncode(legacy)),
            throwsInvalid('hardened-only'),
          );
        }
        // v1 keys with a v2 field, and v2 without its fields.
        expect(
          () => ToolchainSecurity.parse(
            jsonEncode({
              ...floor(profile: 'legacy', version: 1),
              'release_root': null,
            }),
          ),
          throwsInvalid('unknown keys release_root'),
        );
        expect(
          () => ToolchainSecurity.parse(
            jsonEncode(floor()..remove('release_root')),
          ),
          throwsInvalid('missing keys release_root'),
        );
      });

      test('reads a legacy toolchain with a null toolchain_id', () {
        final security = ToolchainSecurity.parse(
          jsonEncode(floor(profile: 'legacy', toolchainId: null)),
        );
        expect(security.profile, SecurityProfile.legacy);
        expect(security.toolchainId, isNull);
        expect(security.buildEnvironment, isEmpty);
      });

      test('reads a legacy toolchain with a toolchain_id', () {
        final security = ToolchainSecurity.parse(
          jsonEncode(floor(profile: 'legacy')),
        );
        expect(security.toolchainId, hardenedId);
        expect(security.buildEnvironment, isEmpty);
      });

      test('reads development exceptions', () {
        final security = ToolchainSecurity.parse(
          jsonEncode(floor(developmentExceptions: true)),
        );
        expect(security.developmentExceptions, isTrue);
        expect(
          security.buildEnvironment.keys,
          isNot(contains('SHOREBIRD_SECURITY_DEVELOPMENT_EXCEPTIONS')),
        );
      });

      test('rejects malformed JSON', () {
        expect(
          () => ToolchainSecurity.parse('{"schema":'),
          throwsInvalid('not valid JSON'),
        );
      });

      test('rejects a non-object', () {
        expect(
          () => ToolchainSecurity.parse('[]'),
          throwsInvalid('expected a JSON object'),
        );
      });

      test('rejects an unknown key', () {
        expect(
          () => ToolchainSecurity.parse(
            jsonEncode({...floor(), 'diversification_profile_id': null}),
          ),
          throwsInvalid('unknown keys diversification_profile_id'),
        );
      });

      test('rejects a missing key', () {
        expect(
          () => ToolchainSecurity.parse(
            jsonEncode(floor()..remove('development_exceptions')),
          ),
          throwsInvalid('missing keys development_exceptions'),
        );
      });

      test('rejects a wrong schema', () {
        expect(
          () => ToolchainSecurity.parse(
            jsonEncode({...floor(), 'schema': 'shorebird.toolchain'}),
          ),
          throwsInvalid('schema must be'),
        );
      });

      for (final version in [0, 3, '1', 1.5]) {
        test('rejects contract_version ${jsonEncode(version)}', () {
          expect(
            () => ToolchainSecurity.parse(
              jsonEncode({...floor(), 'contract_version': version}),
            ),
            throwsInvalid('unsupported contract_version'),
          );
        });
      }

      for (final profile in ['hardened-diversified', 'strict', '']) {
        test('rejects security_profile "$profile"', () {
          expect(
            () => ToolchainSecurity.parse(jsonEncode(floor(profile: profile))),
            throwsInvalid('security_profile must be'),
          );
        });
      }

      for (final id in [
        'sha256:${'C' * 64}',
        'sha256:${'c' * 63}',
        'sha1:${'c' * 64}',
        'c' * 64,
        42,
      ]) {
        test('rejects toolchain_id ${jsonEncode(id)}', () {
          expect(
            () => ToolchainSecurity.parse(jsonEncode(floor(toolchainId: id))),
            throwsInvalid('toolchain_id must be'),
          );
        });
      }

      test('rejects a hardened toolchain without a toolchain_id', () {
        expect(
          () => ToolchainSecurity.parse(jsonEncode(floor(toolchainId: null))),
          throwsInvalid('requires a toolchain_id'),
        );
      });

      test('rejects a non-bool development_exceptions', () {
        expect(
          () => ToolchainSecurity.parse(
            jsonEncode(floor(developmentExceptions: 'false')),
          ),
          throwsInvalid('development_exceptions must be'),
        );
      });
    });

    group('load', () {
      late Directory shorebirdRoot;

      setUp(() {
        shorebirdRoot = Directory.systemTemp.createTempSync();
      });

      test('treats an absent file as a legacy toolchain', () {
        final security = ToolchainSecurity.load(shorebirdRoot);
        expect(security.profile, SecurityProfile.legacy);
        expect(security.toolchainId, isNull);
        expect(security.developmentExceptions, isFalse);
      });

      test('reads bin/internal/toolchain_security.json', () {
        ToolchainSecurity.fileIn(shorebirdRoot)
          ..createSync(recursive: true)
          ..writeAsStringSync(jsonEncode(floor()));
        expect(
          ToolchainSecurity.fileIn(shorebirdRoot).path,
          endsWith(
            'bin/internal/toolchain_security.json'.replaceAll(
              '/',
              Platform.pathSeparator,
            ),
          ),
        );
        expect(
          ToolchainSecurity.load(shorebirdRoot).profile,
          SecurityProfile.hardened,
        );
      });

      test('names the file when it is invalid', () {
        final file = ToolchainSecurity.fileIn(shorebirdRoot)
          ..createSync(recursive: true)
          ..writeAsStringSync('nope');
        expect(
          () => ToolchainSecurity.load(shorebirdRoot),
          throwsA(
            isA<ToolchainSecurityException>().having(
              (e) => e.message,
              'message',
              startsWith('${file.path} is invalid'),
            ),
          ),
        );
      });

      test('the ref reads the install root of shorebirdEnv', () {
        final shorebirdEnv = MockShorebirdEnv();
        when(() => shorebirdEnv.shorebirdRoot).thenReturn(shorebirdRoot);
        ToolchainSecurity.fileIn(shorebirdRoot)
          ..createSync(recursive: true)
          ..writeAsStringSync(jsonEncode(floor()));
        expect(
          runScoped(
            () => toolchainSecurity.toolchainId,
            values: {
              shorebirdEnvRef.overrideWith(() => shorebirdEnv),
              toolchainSecurityRef,
            },
          ),
          hardenedId,
        );
      });
    });
  });

  group('reservedSecurityKeysIn', () {
    test('finds the reserved top-level keys', () {
      expect(
        reservedSecurityKeysIn('''
app_id: x
security_profile: hardened
security_contract_version: 1
toolchain_id: sha256:abc
security_development_exceptions: true
base_url: https://example.com
'''),
        [
          'security_profile',
          'security_contract_version',
          'toolchain_id',
          'security_development_exceptions',
        ],
      );
    });

    test('ignores clean, nested, and unparsable documents', () {
      expect(reservedSecurityKeysIn('app_id: x\n'), isEmpty);
      expect(
        reservedSecurityKeysIn('flavors:\n  security_profile: x\n'),
        isEmpty,
      );
      expect(reservedSecurityKeysIn('app_id: [\n'), isEmpty);
      expect(reservedSecurityKeysIn('- a\n'), isEmpty);
    });
  });

  group('hardenedShorebirdYamlProblems', () {
    test('accepts https with a host and default verification', () {
      expect(
        hardenedShorebirdYamlProblems(
          const ShorebirdYaml(appId: 'x', baseUrl: 'https://u.example.com'),
        ),
        isEmpty,
      );
    });

    test('requires a shorebird.yaml with base_url', () {
      expect(hardenedShorebirdYamlProblems(null), hasLength(1));
      expect(
        hardenedShorebirdYamlProblems(
          const ShorebirdYaml(appId: 'x', baseUrl: ' '),
        ),
        [contains('must set base_url')],
      );
    });

    test('reports every problem', () {
      expect(
        hardenedShorebirdYamlProblems(
          const ShorebirdYaml(
            appId: 'x',
            baseUrl: 'http://[::1]:8080',
            patchVerification: PatchVerification.installOnly,
            patchResponseVerification: PatchResponseVerification.optional,
          ),
        ),
        [
          contains('must use https'),
          contains('patch_verification'),
          contains('patch_response_verification'),
        ],
      );
    });

    test('rejects a scheme-less base_url', () {
      expect(
        hardenedShorebirdYamlProblems(
          const ShorebirdYaml(appId: 'x', baseUrl: 'u.example.com'),
        ),
        [contains('must use https')],
      );
    });
  });

  group('hardenedBuildManifestProblems', () {
    late String keyPath;
    late String trustPath;

    setUp(() {
      final dir = Directory.systemTemp.createTempSync('manifest-key');
      trustPath =
          (File('${dir.path}/release-trust.json')..writeAsStringSync(
                jsonEncode({
                  'schema': 'open-shorebird.release-trust',
                  'contract_version': 2,
                  'root_chain': <Object>[],
                  'delegations': {'payload': '', 'signatures': <Object>[]},
                }),
              ))
              .path;
      final der = [
        0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, //
        0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
        ...List.filled(32, 7),
      ];
      keyPath =
          (File('${dir.path}/manifest.pem')..writeAsStringSync(
                '-----BEGIN PRIVATE KEY-----\n${base64.encode(der)}\n'
                '-----END PRIVATE KEY-----\n',
              ))
              .path;
    });

    test('accepts a PKCS#8 Ed25519 key and well-formed identities', () {
      expect(
        hardenedBuildManifestProblems({
          buildManifestSigningKeyEnvironmentVariable: keyPath,
          releaseTrustEnvironmentVariable: trustPath,
          androidSigningCertEnvironmentVariable:
              '${'ab' * 32}, AB:${'CD:' * 30}EF',
        }, platform: 'android'),
        isEmpty,
      );
      expect(
        hardenedBuildManifestProblems({
          buildManifestSigningKeyEnvironmentVariable: keyPath,
          releaseTrustEnvironmentVariable: trustPath,
          appleTeamIdsEnvironmentVariable: 'ABCDE12345',
        }, platform: 'macos'),
        isEmpty,
      );
    });

    test('refuses a missing, unreadable or non-Ed25519 key', () {
      final rsa = File('${File(keyPath).parent.path}/rsa.pem')
        ..writeAsStringSync(
          File(keyPath).readAsStringSync().replaceFirst('MC4C', 'MC8C'),
        );
      for (final environment in [
        <String, String>{},
        {buildManifestSigningKeyEnvironmentVariable: ''},
        {buildManifestSigningKeyEnvironmentVariable: '/no/such/key.pem'},
        {buildManifestSigningKeyEnvironmentVariable: rsa.path},
      ]) {
        expect(
          hardenedBuildManifestProblems(environment, platform: 'linux'),
          isNotEmpty,
          reason: '$environment',
        );
      }
    });

    test('refuses identities the target platform cannot verify', () {
      for (final (platform, environment) in [
        ('ios', {appleTeamIdsEnvironmentVariable: 'ABCDE12345'}),
        ('linux', {androidSigningCertEnvironmentVariable: 'ab' * 32}),
        ('android', {androidSigningCertEnvironmentVariable: 'abc'}),
        ('macos', {appleTeamIdsEnvironmentVariable: 'abcde12345'}),
      ]) {
        expect(
          hardenedBuildManifestProblems({
            buildManifestSigningKeyEnvironmentVariable: keyPath,
            releaseTrustEnvironmentVariable: trustPath,
            ...environment,
          }, platform: platform),
          isNotEmpty,
          reason: '$platform $environment',
        );
      }
    });

    test('requires a contract v2 release-trust bundle', () {
      final notTrust = File('${File(keyPath).parent.path}/other.json')
        ..writeAsStringSync('{"schema":"open-shorebird.release-root"}');
      final notJson = File('${File(keyPath).parent.path}/garbage.json')
        ..writeAsStringSync('garbage');
      for (final trust in [
        null,
        '',
        '/no/such/trust.json',
        notTrust.path,
        notJson.path,
      ]) {
        expect(
          hardenedBuildManifestProblems({
            buildManifestSigningKeyEnvironmentVariable: keyPath,
            releaseTrustEnvironmentVariable: ?trust,
          }, platform: 'linux'),
          [contains(releaseTrustEnvironmentVariable)],
          reason: '$trust',
        );
      }
    });

    test('accepts exactly one signer: a key file or an external signer', () {
      final keyId = 'sha256:${'a' * 64}';
      expect(
        hardenedBuildManifestProblems({
          releaseTrustEnvironmentVariable: trustPath,
          buildManifestSignerEnvironmentVariable: '/opt/kms-signer',
          buildManifestSignerKeyIdEnvironmentVariable: keyId,
        }, platform: 'linux'),
        isEmpty,
      );
      for (final environment in [
        {
          buildManifestSigningKeyEnvironmentVariable: keyPath,
          buildManifestSignerEnvironmentVariable: '/opt/kms-signer',
          buildManifestSignerKeyIdEnvironmentVariable: keyId,
        },
        {buildManifestSignerEnvironmentVariable: '/opt/kms-signer'},
        {
          buildManifestSignerEnvironmentVariable: '/opt/kms-signer',
          buildManifestSignerKeyIdEnvironmentVariable: 'sha256:ABC',
        },
      ]) {
        expect(
          hardenedBuildManifestProblems({
            releaseTrustEnvironmentVariable: trustPath,
            ...environment,
          }, platform: 'linux'),
          hasLength(1),
          reason: '$environment',
        );
      }
    });

    test('reserves the manifest key in checked-in shorebird.yaml', () {
      expect(
        reservedSecurityKeysIn('app_id: a\nshorebird_build_manifest: x\n'),
        ['shorebird_build_manifest'],
      );
    });
  });

  group('readReleaseRecord', () {
    late Directory directory;

    Map<String, Object?> record(String digest, {int delegations = 1}) => {
      'schema': 'open-shorebird.release-record',
      'contract_version': 2,
      'security_profile': 'hardened',
      'toolchain_id': hardenedId,
      'development_exceptions': false,
      'release_root_sha256': 'sha256:${'1' * 64}',
      'root_version': 1,
      'delegations_version': delegations,
      'delegations_sha256': '2' * 64,
      'build_manifests': [
        {
          'manifest_sha256': digest,
          'signer_key_id': 'sha256:${'3' * 64}',
          'config_sha256': '4' * 64,
          'modules': <Object>[],
        },
      ],
    };

    void write(String name, Object? document) => File(
      p.join(directory.path, name),
    ).writeAsStringSync(jsonEncode(document));

    setUp(() {
      directory = Directory.systemTemp.createTempSync('release-record');
    });

    test('merges the per-build records, one entry per manifest', () {
      write('build-manifest-b.json', record('b' * 64));
      write('build-manifest-a.json', record('a' * 64));
      write('build-manifest-a2.json', record('a' * 64));
      final merged = readReleaseRecord(directory);
      expect(merged['toolchain_id'], hardenedId);
      expect(
        [
          for (final m in merged['build_manifests']! as List<Object?>)
            (m! as Map<String, Object?>)['manifest_sha256'],
        ],
        ['a' * 64, 'b' * 64],
      );
    });

    test('refuses a missing, malformed or inconsistent record', () {
      expect(
        () => readReleaseRecord(Directory(p.join(directory.path, 'none'))),
        throwsA(isA<ReleaseRecordException>()),
      );
      write('build-manifest-a.json', record('a' * 64));
      write('build-manifest-b.json', record('b' * 64, delegations: 2));
      expect(
        () => readReleaseRecord(directory),
        throwsA(
          isA<ReleaseRecordException>().having(
            (e) => e.message,
            'message',
            contains('disagree'),
          ),
        ),
      );
      write('build-manifest-b.json', {...record('b' * 64), 'schema': 'x'});
      expect(
        () => readReleaseRecord(directory),
        throwsA(isA<ReleaseRecordException>()),
      );
    });
  });
}
