import 'dart:convert';
import 'dart:io';

import 'package:mocktail/mocktail.dart';
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

  Map<String, Object?> floor({
    String profile = 'hardened',
    Object? toolchainId = '',
    Object? developmentExceptions = false,
  }) => {
    'schema': 'open-shorebird.toolchain-security',
    'contract_version': 1,
    'security_profile': profile,
    'toolchain_id': toolchainId == '' ? hardenedId : toolchainId,
    'development_exceptions': developmentExceptions,
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
        expect(security.buildEnvironment, {
          'SHOREBIRD_SECURITY_PROFILE': 'hardened',
          'SHOREBIRD_TOOLCHAIN_ID': hardenedId,
        });
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

      for (final version in [0, 2, '1', 1.5]) {
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

    setUp(() {
      final dir = Directory.systemTemp.createTempSync('manifest-key');
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
          androidSigningCertEnvironmentVariable:
              '${'ab' * 32}, AB:${'CD:' * 30}EF',
        }, platform: 'android'),
        isEmpty,
      );
      expect(
        hardenedBuildManifestProblems({
          buildManifestSigningKeyEnvironmentVariable: keyPath,
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
            ...environment,
          }, platform: platform),
          isNotEmpty,
          reason: '$platform $environment',
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
}
