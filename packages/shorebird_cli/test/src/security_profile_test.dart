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

  // A production diversification profile ID (contract v3).
  final profileId = 'sha256:${'d' * 64}';

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
    if (version >= 2) ...{
      'release_root': profile.startsWith('hardened') ? releaseRoot : null,
      'min_delegations_version': 1,
    },
    if (version == 3) 'diversification_profile_id': profileId,
  };

  Map<String, Object?> diversifiedFloor() =>
      floor(profile: 'hardened-diversified', version: 3);

  Matcher throwsInvalid(String reason) => throwsA(
    isA<ToolchainSecurityException>().having(
      (e) => e.message,
      'message',
      allOf(contains('is invalid'), contains(reason)),
    ),
  );

  group(SecurityProfile, () {
    test('parses the contract v3 profiles', () {
      expect(SecurityProfile.tryParse('legacy'), SecurityProfile.legacy);
      expect(SecurityProfile.tryParse('hardened'), SecurityProfile.hardened);
      expect(
        SecurityProfile.tryParse('hardened-diversified'),
        SecurityProfile.hardenedDiversified,
      );
      expect(SecurityProfile.tryParse('Hardened'), isNull);
      expect(SecurityProfile.tryParse('hardenedDiversified'), isNull);
      for (final profile in SecurityProfile.values) {
        expect(SecurityProfile.tryParse(profile.value), profile);
      }
      expect(SecurityProfile.legacy.isHardened, isFalse);
      expect(SecurityProfile.hardened.isHardened, isTrue);
      expect(SecurityProfile.hardenedDiversified.isHardened, isTrue);
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

      test('reads a contract v3 hardened-diversified toolchain', () {
        final security = ToolchainSecurity.parse(
          jsonEncode(diversifiedFloor()),
        );
        expect(security.profile, SecurityProfile.hardenedDiversified);
        expect(security.diversificationProfileId, profileId);
        expect(security.releaseRoot, releaseRoot);
        expect(security.buildEnvironment, {
          'SHOREBIRD_SECURITY_PROFILE': 'hardened-diversified',
          'SHOREBIRD_TOOLCHAIN_ID': hardenedId,
          'SHOREBIRD_RELEASE_ROOT': releaseRoot,
          'SHOREBIRD_RELEASE_MIN_DELEGATIONS_VERSION': '1',
          'SHOREBIRD_DIVERSIFICATION_PROFILE_ID': profileId,
        });
      });

      test('hardened and legacy toolchains carry no diversification '
          'profile', () {
        for (final document in [
          floor(),
          floor(profile: 'legacy', toolchainId: null),
          floor(profile: 'legacy', toolchainId: null, version: 1),
        ]) {
          final security = ToolchainSecurity.parse(jsonEncode(document));
          expect(security.diversificationProfileId, isNull);
          expect(
            security.buildEnvironment.containsKey(
              'SHOREBIRD_DIVERSIFICATION_PROFILE_ID',
            ),
            isFalse,
          );
        }
      });

      group('refuses a contract v3 file', () {
        final cases = <String, (Map<String, Object?>, String)>{
          'v1 with diversification_profile_id': (
            {
              ...floor(profile: 'legacy', toolchainId: null, version: 1),
              'diversification_profile_id': 'sha256:${'d' * 64}',
            },
            'unknown keys diversification_profile_id',
          ),
          'v2 with diversification_profile_id': (
            {...floor(), 'diversification_profile_id': 'sha256:${'d' * 64}'},
            'unknown keys diversification_profile_id',
          ),
          'v2 hardened-diversified': (
            floor(profile: 'hardened-diversified'),
            'needs contract_version 3',
          ),
          'v3 without diversification_profile_id': (
            diversifiedFloor()..remove('diversification_profile_id'),
            'missing keys diversification_profile_id',
          ),
          'v3 hardened': (
            {...diversifiedFloor(), 'security_profile': 'hardened'},
            'contract_version 3 is used only by hardened-diversified',
          ),
          'v3 legacy': (
            {
              ...diversifiedFloor(),
              'security_profile': 'legacy',
              'release_root': null,
            },
            'contract_version 3 is used only by hardened-diversified',
          ),
          'v3 with a null profile id': (
            {...diversifiedFloor(), 'diversification_profile_id': null},
            'diversification_profile_id must be',
          ),
          'v3 with a malformed profile id': (
            {
              ...diversifiedFloor(),
              'diversification_profile_id': 'sha256:${'D' * 64}',
            },
            'diversification_profile_id must be',
          ),
          'v3 without a release root': (
            {...diversifiedFloor(), 'release_root': null},
            'needs a release_root',
          ),
          'v3 without a toolchain_id': (
            {...diversifiedFloor(), 'toolchain_id': null},
            'requires a toolchain_id',
          ),
          'v3 production with the DEVELOPMENT-ONLY profile': (
            {
              ...diversifiedFloor(),
              'diversification_profile_id': developmentDiversificationProfileId,
            },
            'DEVELOPMENT-ONLY',
          ),
        };
        for (final MapEntry(key: name, value: (document, message))
            in cases.entries) {
          test(name, () {
            expect(
              () => ToolchainSecurity.parse(jsonEncode(document)),
              throwsInvalid(message),
            );
          });
        }
      });

      test('a development v3 toolchain may use the DEVELOPMENT-ONLY '
          'profile', () {
        final security = ToolchainSecurity.parse(
          jsonEncode({
            ...diversifiedFloor(),
            'development_exceptions': true,
            'diversification_profile_id': developmentDiversificationProfileId,
          }),
        );
        expect(
          security.diversificationProfileId,
          developmentDiversificationProfileId,
        );
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

      for (final version in [0, 4, '1', 1.5]) {
        test('rejects contract_version ${jsonEncode(version)}', () {
          expect(
            () => ToolchainSecurity.parse(
              jsonEncode({...floor(), 'contract_version': version}),
            ),
            throwsInvalid('unsupported contract_version'),
          );
        });
      }

      for (final profile in ['strict', 'hardenedDiversified', '']) {
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

    test('reserves diversification_profile_id in checked-in '
        'shorebird.yaml', () {
      expect(
        reservedSecurityKeysIn(
          'app_id: a\ndiversification_profile_id: sha256:x\n',
        ),
        ['diversification_profile_id'],
      );
    });
  });

  group('readReleaseRecord', () {
    late Directory directory;

    Map<String, Object?> record(
      String digest, {
      int delegations = 1,
      String? diversificationProfileId,
    }) => {
      'schema': 'open-shorebird.release-record',
      'contract_version': diversificationProfileId == null ? 2 : 3,
      'security_profile': diversificationProfileId == null
          ? 'hardened'
          : 'hardened-diversified',
      'diversification_profile_id': ?diversificationProfileId,
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

    group('hardened-diversified (release-record v3)', () {
      test('merges v3 records for the expected profile', () {
        write('a.json', record('a' * 64, diversificationProfileId: profileId));
        write('b.json', record('b' * 64, diversificationProfileId: profileId));
        final merged = readReleaseRecord(
          directory,
          diversificationProfileId: profileId,
        );
        expect(merged['contract_version'], 3);
        expect(merged['security_profile'], 'hardened-diversified');
        expect(merged['diversification_profile_id'], profileId);
        expect(merged['build_manifests'], hasLength(2));
      });

      final otherId = 'sha256:${'e' * 64}';
      final refused = <String, (Map<String, Object?>, String?)>{
        'a v2 record for a diversified release': (record('a' * 64), profileId),
        'a v3 record for another profile': (
          record('a' * 64, diversificationProfileId: otherId),
          profileId,
        ),
        'a v3 record without the profile id': (
          record('a' * 64, diversificationProfileId: profileId)
            ..remove('diversification_profile_id'),
          profileId,
        ),
        'a v3 record that claims hardened': (
          {
            ...record('a' * 64, diversificationProfileId: profileId),
            'security_profile': 'hardened',
          },
          profileId,
        ),
        'a v3 record for a hardened release': (
          record('a' * 64, diversificationProfileId: profileId),
          null,
        ),
        'a v2 record naming a profile for a hardened release': (
          {...record('a' * 64), 'diversification_profile_id': profileId},
          null,
        ),
      };
      for (final MapEntry(key: name, value: (document, expected))
          in refused.entries) {
        test('refuses $name', () {
          write('a.json', document);
          expect(
            () => readReleaseRecord(
              directory,
              diversificationProfileId: expected,
            ),
            throwsA(isA<ReleaseRecordException>()),
          );
        });
      }

      test('refuses records that disagree on the profile', () {
        // Both name the expected profile in the shared fields checked per
        // file, so only the merge can catch a difference elsewhere.
        write('a.json', record('a' * 64, diversificationProfileId: profileId));
        write('b.json', {
          ...record('b' * 64, diversificationProfileId: profileId),
          'toolchain_id': 'sha256:${'f' * 64}',
        });
        expect(
          () => readReleaseRecord(
            directory,
            diversificationProfileId: profileId,
          ),
          throwsA(
            isA<ReleaseRecordException>().having(
              (e) => e.message,
              'message',
              contains('disagree'),
            ),
          ),
        );
      });
    });
  });

  group(BytecodeProfile, () {
    final developmentFixture = developmentDiversificationProfilePath;

    Map<String, Object?> developmentProfile() =>
        jsonDecode(File(developmentFixture).readAsStringSync())
            as Map<String, Object?>;

    String write(Object? document, {String name = 'profile.json'}) {
      final file = File(p.join(Directory.current.path, name))
        ..writeAsStringSync(
          document is String ? document : jsonEncode(document),
        );
      return file.path;
    }

    // A valid production-like profile: the development permutation with
    // two non-Trap entries swapped.
    Map<String, Object?> productionProfile() {
      final profile = developmentProfile();
      final wires =
          (profile['bytecode']! as Map<String, Object?>)['wire_opcodes']!
              as List<Object?>;
      final first = wires[1];
      wires[1] = wires[2];
      wires[2] = first;
      return profile;
    }

    ToolchainSecurity toolchainFor(String id, {bool development = false}) =>
        ToolchainSecurity(
          profile: SecurityProfile.hardenedDiversified,
          toolchainId: hardenedId,
          developmentExceptions: development,
          releaseRoot: releaseRoot,
          diversificationProfileId: id,
        );

    test('computes the reference profile id of the shared fixture', () {
      // scripts/diversification_profile.py id
      // scripts/testdata/diversification/profile.DEVELOPMENT-ONLY.json
      final profile = BytecodeProfile.load(developmentFixture);
      expect(profile.id, developmentDiversificationProfileId);
      expect(profile.path, p.absolute(developmentFixture));
      expect(profile.digest, hasLength(32));
      expect(
        profile.digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        developmentDiversificationProfileId.substring('sha256:'.length),
      );
    });

    test('the id does not depend on formatting or key order', () {
      final compact = write(
        jsonEncode(developmentProfile()),
        name: 'compact.json',
      );
      expect(
        BytecodeProfile.load(compact).id,
        developmentDiversificationProfileId,
      );
    });

    group('refuses', () {
      Map<String, Object?> changed(void Function(Map<String, Object?>) change) {
        final profile = productionProfile();
        change(profile);
        return profile;
      }

      Map<String, Object?> bytecode(Map<String, Object?> profile) =>
          profile['bytecode']! as Map<String, Object?>;

      List<Object?> wires(Map<String, Object?> profile) =>
          bytecode(profile)['wire_opcodes']! as List<Object?>;

      final cases = <String, Object?>{
        'a non-object': <Object>[],
        'another schema': changed((d) => d['schema'] = 'x'),
        'another contract version': changed((d) => d['contract_version'] = 2),
        'a non-null native layout': changed((d) => d['native_layout'] = {}),
        'a missing native layout': changed((d) => d.remove('native_layout')),
        'an unknown key': changed((d) => d['extra'] = 1),
        'another scheme': changed((d) => bytecode(d)['scheme'] = 'x'),
        'another format version': changed(
          (d) => bytecode(d)['format_version'] = 2,
        ),
        'a malformed opcode table hash': changed(
          (d) => bytecode(d)['opcode_table_sha256'] = 'A' * 64,
        ),
        'an unknown bytecode key': changed((d) => bytecode(d)['extra'] = 1),
        'a non-permutation': changed((d) => wires(d)[1] = wires(d)[2]),
        'an out-of-range wire byte': changed(
          (d) => wires(d)[1] = wires(d).length,
        ),
        'a negative wire byte': changed((d) => wires(d)[1] = -1),
        'a non-integer wire byte': changed((d) => wires(d)[1] = 1.5),
        'a single opcode': changed(
          (d) => bytecode(d)['wire_opcodes'] = <int>[0],
        ),
        'more than 256 opcodes': changed(
          (d) => bytecode(d)['wire_opcodes'] = [
            for (var i = 0; i < 257; i++) (i + 1) % 257,
          ],
        ),
        'Trap moved off wire byte 0': changed((d) {
          final list = wires(d);
          final one = list[1];
          list[1] = list[0];
          list[0] = one;
        }),
        '16 fixed points besides Trap': changed((d) {
          final list = wires(d);
          for (var semantic = 1; semantic <= 16; semantic++) {
            final at = list.indexOf(semantic);
            list[at] = list[semantic];
            list[semantic] = semantic;
          }
        }),
      };
      for (final MapEntry(key: name, value: document) in cases.entries) {
        test(name, () {
          final path = write(document);
          expect(
            () => BytecodeProfile.load(path),
            throwsA(
              isA<BytecodeProfileException>().having(
                (e) => e.message,
                'message',
                contains('is not a diversification profile'),
              ),
            ),
          );
        });
      }

      test('a missing file', () {
        expect(
          () => BytecodeProfile.load(p.join(Directory.current.path, 'none')),
          throwsA(
            isA<BytecodeProfileException>().having(
              (e) => e.message,
              'message',
              contains('cannot be read'),
            ),
          ),
        );
      });

      test('malformed JSON and duplicate keys', () {
        final source = jsonEncode(productionProfile());
        for (final bad in [
          '{',
          source.replaceFirst('{', '{"native_layout":null,'),
          source.replaceFirst(
            '"scheme"',
            r'"sch\u0065me":"opcode-permutation-v1","scheme"',
          ),
        ]) {
          expect(
            () => BytecodeProfile.load(write(bad)),
            throwsA(
              isA<BytecodeProfileException>().having(
                (e) => e.message,
                'message',
                contains('is not valid JSON'),
              ),
            ),
            reason: bad.length > 60 ? bad.substring(0, 60) : bad,
          );
        }
      });
    });

    group('forToolchain', () {
      test('admits the profile the toolchain was built with', () {
        final path = write(productionProfile());
        final id = BytecodeProfile.load(path).id;
        final profile = BytecodeProfile.forToolchain({
          diversificationProfileEnvironmentVariable: path,
        }, toolchainFor(id));
        expect(profile.id, id);
        expect(profile.path, path);
      });

      test('refuses an unset variable', () {
        for (final environment in [
          <String, String>{},
          {diversificationProfileEnvironmentVariable: ''},
        ]) {
          expect(
            () => BytecodeProfile.forToolchain(
              environment,
              toolchainFor(profileId),
            ),
            throwsA(
              isA<BytecodeProfileException>().having(
                (e) => e.message,
                'message',
                contains('Set SHOREBIRD_DIVERSIFICATION_PROFILE'),
              ),
            ),
          );
        }
      });

      test('refuses a profile the toolchain was not built with', () {
        final path = write(productionProfile());
        expect(
          () => BytecodeProfile.forToolchain({
            diversificationProfileEnvironmentVariable: path,
          }, toolchainFor(profileId)),
          throwsA(
            isA<BytecodeProfileException>().having(
              (e) => e.message,
              'message',
              contains('but this toolchain was built with $profileId'),
            ),
          ),
        );
      });

      test('the DEVELOPMENT-ONLY profile needs a development toolchain', () {
        final environment = {
          diversificationProfileEnvironmentVariable: developmentFixture,
        };
        expect(
          () => BytecodeProfile.forToolchain(
            environment,
            toolchainFor(developmentDiversificationProfileId),
          ),
          throwsA(
            isA<BytecodeProfileException>().having(
              (e) => e.message,
              'message',
              contains('DEVELOPMENT-ONLY'),
            ),
          ),
        );
        expect(
          BytecodeProfile.forToolchain(
            environment,
            toolchainFor(
              developmentDiversificationProfileId,
              development: true,
            ),
          ).id,
          developmentDiversificationProfileId,
        );
      });
    });
  });
}
