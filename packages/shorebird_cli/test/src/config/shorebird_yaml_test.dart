import 'dart:convert';

import 'package:checked_yaml/checked_yaml.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:test/test.dart';
import '../helpers.dart';

void main() {
  useTempWorkingDirectory();
  group('ShorebirdYaml', () {
    group('nativePatchMaxBytes', () {
      test('leaves the legacy JSON unchanged when absent', () {
        final yaml = ShorebirdYaml.fromJson({'app_id': 'app'});
        expect(yaml.nativePatchMaxBytes, isNull);
        expect(yaml.toJson(), {
          'app_id': 'app',
          'flavors': null,
          'base_url': null,
          'auto_update': null,
          'patch_verification': null,
          'patch_response_verification': null,
          'aot_patch_runtime_mode': null,
          'aot_patch_bytecode_path': null,
          'aot_patch_key_id': null,
          'aot_patch_key_hex': null,
          'aot_patch_app_build_id': null,
          'aot_patch_base_flavor_id': null,
          'aot_patch_base_license_type': null,
          'aot_patch_flavor_id': null,
          'aot_patch_license_type': null,
          'aot_patch_sdk_hash': null,
          'aot_patch_base_snapshot_hash': null,
          'aot_patch_obfuscation_map_hash': null,
          'aot_patch_offline_expires_at': null,
        });
      });

      for (final bytes in [1, 536870912, 0x7fffffffffffffff]) {
        test('round-trips $bytes with flavors and security fields', () {
          final yaml = checkedYamlDecode(
            '''
app_id: app
flavors:
  paid: paid-app
base_url: https://example.com
auto_update: false
patch_verification: strict
patch_response_verification: required
native_patch_max_bytes: $bytes
''',
            (map) => ShorebirdYaml.fromJson(map!),
          );
          expect(yaml.nativePatchMaxBytes, bytes);
          expect(yaml.getAppId(flavor: 'paid'), 'paid-app');
          expect(yaml.autoUpdate, isFalse);
          expect(yaml.patchVerification, PatchVerification.strict);
          expect(
            yaml.patchResponseVerification,
            PatchResponseVerification.required,
          );
          final json = yaml.toJson();
          expect(json['native_patch_max_bytes'], bytes);
          expect(json['flavors'], {'paid': 'paid-app'});
          expect(json['patch_verification'], 'strict');
          expect(json['patch_response_verification'], 'required');
          expect(ShorebirdYaml.fromJson(json).toJson(), json);
        });
      }

      for (final value in <Object?>[
        null,
        true,
        false,
        '1024',
        1.0,
        1.5,
        double.infinity,
        double.nan,
        0,
        -1,
        BigInt.one << 63,
      ]) {
        test('rejects invalid JSON value $value before conversion', () {
          expect(
            () => ShorebirdYaml.fromJson({
              'app_id': 'app',
              'native_patch_max_bytes': value,
            }),
            throwsA(
              isA<CheckedFromJsonException>()
                  .having((error) => error.key, 'key', 'native_patch_max_bytes')
                  .having(
                    (error) => error.message,
                    'message',
                    contains('positive integer no greater than'),
                  ),
            ),
          );
        });
      }

      test('rejects overflowing decoded JSON instead of saturating it', () {
        final json =
            jsonDecode(
                  '{"app_id":"app",'
                  '"native_patch_max_bytes":9223372036854775808}',
                )
                as Map<String, dynamic>;
        expect(
          () => ShorebirdYaml.fromJson(json),
          throwsA(isA<CheckedFromJsonException>()),
        );
      });

      for (final value in [
        'null',
        'true',
        'false',
        '"1024"',
        '1.0',
        '1.5',
        '0',
        '-1',
        '9223372036854775808',
      ]) {
        test('rejects invalid checked-in YAML value $value', () {
          expect(
            () => checkedYamlDecode(
              'app_id: app\nnative_patch_max_bytes: $value\n',
              (map) => ShorebirdYaml.fromJson(map!),
            ),
            throwsA(
              isA<ParsedYamlException>().having(
                (error) => error.message,
                'message',
                contains('positive integer no greater than'),
              ),
            ),
          );
        });
      }
    });

    for (final enabled in [false, true]) {
      test('round-trips full replacement profile $enabled', () {
        final yaml = ShorebirdYaml.fromJson({
          'app_id': 'app',
          'aot_patch_runtime_mode': 'dart-bytecode-interpreter',
          'aot_patch_full_replacement': enabled,
        });
        expect(yaml.aotPatchFullReplacement, enabled);
        expect(yaml.toJson()['aot_patch_full_replacement'], enabled);
      });
    }
    for (final extra in <Map<String, Object?>>[
      {'aot_patch_full_replacement': 'true'},
      {'aot_patch_full_replacement': null},
      {
        'aot_patch_full_replacement': true,
        'aot_patch_structural_updates': true,
      },
      {
        'aot_patch_full_replacement': true,
        'aot_patch_runtime_mode': 'native-aot',
      },
    ]) {
      test('rejects invalid full replacement configuration $extra', () {
        expect(
          () => ShorebirdYaml.fromJson({
            'app_id': 'app',
            'aot_patch_runtime_mode': 'dart-bytecode-interpreter',
            ...extra,
          }),
          throwsA(isA<Exception>()),
        );
      });
    }
    for (final enabled in [false, true]) {
      test('serializes strict structural profile $enabled', () {
        final yaml = ShorebirdYaml.fromJson({
          'app_id': 'app',
          'aot_patch_runtime_mode': 'dart-bytecode-interpreter',
          'aot_patch_structural_updates': enabled,
        });
        expect(yaml.aotPatchStructuralUpdates, enabled);
        expect(yaml.toJson()['aot_patch_structural_updates'], enabled);
      });
    }
    for (final invalid in <Object?>['true', 'false', 1, null]) {
      test('rejects non-boolean structural profile $invalid', () {
        expect(
          () => ShorebirdYaml.fromJson({
            'app_id': 'app',
            'aot_patch_runtime_mode': 'dart-bytecode-interpreter',
            'aot_patch_structural_updates': invalid,
          }),
          throwsA(isA<Exception>()),
        );
      });
    }
    for (final mode in <String?>[null, 'native-aot']) {
      test('rejects structural opt-in outside interpreter mode $mode', () {
        expect(
          () => checkedYamlDecode(
            'app_id: app\n'
            '${mode == null ? '' : 'aot_patch_runtime_mode: $mode\n'}'
            'aot_patch_structural_updates: true\n',
            (map) => ShorebirdYaml.fromJson(map!),
          ),
          throwsA(
            isA<ParsedYamlException>().having(
              (error) => error.message,
              'message',
              contains('aot_patch_runtime_mode: dart-bytecode-interpreter'),
            ),
          ),
        );
      });
    }

    test('can be deserialized without flavors', () {
      const yaml = '''
app_id: test_app_id
base_url: https://example.com
''';
      final shorebirdYaml = checkedYamlDecode(
        yaml,
        (m) => ShorebirdYaml.fromJson(m!),
      );
      expect(shorebirdYaml.appId, 'test_app_id');
      expect(shorebirdYaml.flavors, isNull);
      expect(shorebirdYaml.baseUrl, 'https://example.com');
    });

    test('can be deserialized with flavors', () {
      const yaml = '''
app_id: test_app_id1
flavors:
  development: test_app_id1
  production: test_app_id2
base_url: https://example.com
''';
      final shorebirdYaml = checkedYamlDecode(
        yaml,
        (m) => ShorebirdYaml.fromJson(m!),
      );
      expect(shorebirdYaml.appId, equals('test_app_id1'));
      expect(shorebirdYaml.flavors, {
        'development': 'test_app_id1',
        'production': 'test_app_id2',
      });
      expect(shorebirdYaml.baseUrl, 'https://example.com');
    });

    test('can be deserialized without auto-update', () {
      const yaml = '''
app_id: test_app_id
''';
      final shorebirdYaml = checkedYamlDecode(
        yaml,
        (m) => ShorebirdYaml.fromJson(m!),
      );
      expect(shorebirdYaml.appId, 'test_app_id');
      expect(shorebirdYaml.flavors, isNull);
      expect(shorebirdYaml.baseUrl, isNull);
      expect(shorebirdYaml.autoUpdate, isNull);
    });

    test('can be deserialized with auto-update', () {
      const yaml = '''
app_id: test_app_id
auto_update: true
''';
      final shorebirdYaml = checkedYamlDecode(
        yaml,
        (m) => ShorebirdYaml.fromJson(m!),
      );
      expect(shorebirdYaml.appId, 'test_app_id');
      expect(shorebirdYaml.flavors, isNull);
      expect(shorebirdYaml.baseUrl, isNull);
      expect(shorebirdYaml.autoUpdate, isTrue);
    });

    test('can be deserialized without patch_verification', () {
      const yaml = '''
app_id: test_app_id
''';
      final shorebirdYaml = checkedYamlDecode(
        yaml,
        (m) => ShorebirdYaml.fromJson(m!),
      );
      expect(shorebirdYaml.appId, 'test_app_id');
      expect(shorebirdYaml.patchVerification, isNull);
    });

    test('can be deserialized with patch_verification: strict', () {
      const yaml = '''
app_id: test_app_id
patch_verification: strict
''';
      final shorebirdYaml = checkedYamlDecode(
        yaml,
        (m) => ShorebirdYaml.fromJson(m!),
      );
      expect(shorebirdYaml.appId, 'test_app_id');
      expect(shorebirdYaml.patchVerification, PatchVerification.strict);
    });

    test('can be deserialized with patch_verification: install_only', () {
      const yaml = '''
app_id: test_app_id
patch_verification: install_only
''';
      final shorebirdYaml = checkedYamlDecode(
        yaml,
        (m) => ShorebirdYaml.fromJson(m!),
      );
      expect(shorebirdYaml.appId, 'test_app_id');
      expect(shorebirdYaml.patchVerification, PatchVerification.installOnly);
    });

    for (final mode in PatchResponseVerification.values) {
      test('serializes patch_response_verification: ${mode.name}', () {
        final config = checkedYamlDecode(
          'app_id: test_app_id\npatch_response_verification: ${mode.name}',
          (map) => ShorebirdYaml.fromJson(map!),
        );
        expect(config.patchResponseVerification, mode);
        expect(config.toJson()['patch_response_verification'], mode.name);
      });
    }

    test('rejects invalid patch_response_verification', () {
      expect(
        () => checkedYamlDecode(
          'app_id: test_app_id\npatch_response_verification: invalid',
          (map) => ShorebirdYaml.fromJson(map!),
        ),
        throwsA(
          isA<ParsedYamlException>().having(
            (error) => error.message,
            'message',
            contains('patch_response_verification'),
          ),
        ),
      );
    });

    test('defaults patch_response_verification to absent for legacy apps', () {
      final config = ShorebirdYaml.fromJson({'app_id': 'test_app_id'});
      expect(config.patchResponseVerification, isNull);
    });

    test('can be deserialized with open AOT patch metadata', () {
      const yaml = '''
app_id: test_app_id
aot_patch_runtime_mode: dart-bytecode-interpreter
aot_patch_bytecode_path: build/patch.interp
aot_patch_key_id: test-key
aot_patch_key_hex: 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
aot_patch_app_build_id: 1.2.3+4
aot_patch_base_flavor_id: free
aot_patch_base_license_type: free
aot_patch_flavor_id: pro
aot_patch_license_type: pro
aot_patch_sdk_hash: sdk-hash
aot_patch_base_snapshot_hash: base-hash
aot_patch_obfuscation_map_hash: obfuscation-hash
aot_patch_offline_expires_at: 2030-01-01T00:00:00Z
''';
      final shorebirdYaml = checkedYamlDecode(
        yaml,
        (m) => ShorebirdYaml.fromJson(m!),
      );
      expect(
        shorebirdYaml.aotPatchRuntimeMode,
        'dart-bytecode-interpreter',
      );
      expect(shorebirdYaml.aotPatchBytecodePath, 'build/patch.interp');
      expect(shorebirdYaml.aotPatchKeyId, 'test-key');
      expect(shorebirdYaml.aotPatchAppBuildId, '1.2.3+4');
      expect(shorebirdYaml.aotPatchBaseFlavorId, 'free');
      expect(shorebirdYaml.aotPatchBaseLicenseType, 'free');
      expect(shorebirdYaml.aotPatchFlavorId, 'pro');
      expect(shorebirdYaml.aotPatchLicenseType, 'pro');
      expect(shorebirdYaml.aotPatchSdkHash, 'sdk-hash');
      expect(shorebirdYaml.aotPatchBaseSnapshotHash, 'base-hash');
      expect(shorebirdYaml.aotPatchObfuscationMapHash, 'obfuscation-hash');
      expect(
        shorebirdYaml.aotPatchOfflineExpiresAt,
        '2030-01-01T00:00:00Z',
      );
    });

    test('throws when patch_verification has invalid value', () {
      const yaml = '''
app_id: test_app_id
patch_verification: invalid_value
''';
      expect(
        () => checkedYamlDecode(yaml, (m) => ShorebirdYaml.fromJson(m!)),
        throwsA(
          isA<ParsedYamlException>().having(
            (e) => e.message,
            'message',
            contains('patch_verification'),
          ),
        ),
      );
    });

    group('AppIdExtension', () {
      test('getAppId returns base app id when no flavor is provided', () {
        const shorebirdYaml = ShorebirdYaml(appId: 'test_app_id');
        expect(shorebirdYaml.getAppId(), 'test_app_id');
      });

      test('getAppId returns base app id when flavor is not found', () {
        const shorebirdYaml = ShorebirdYaml(
          appId: 'test_app_id',
          flavors: {
            'development': 'test_app_id1',
            'production': 'test_app_id2',
          },
        );
        expect(shorebirdYaml.getAppId(flavor: 'staging'), 'test_app_id');
      });

      test('getAppId returns app id for flavor', () {
        const shorebirdYaml = ShorebirdYaml(
          appId: 'test_app_id',
          flavors: {
            'development': 'test_app_id1',
            'production': 'test_app_id2',
          },
        );
        expect(shorebirdYaml.getAppId(flavor: 'development'), 'test_app_id1');
        expect(shorebirdYaml.getAppId(flavor: 'production'), 'test_app_id2');
      });

      group('unknownFlavorError', () {
        const flavoredYaml = ShorebirdYaml(
          appId: 'test_app_id',
          flavors: {
            'development': 'test_app_id1',
            'production': 'test_app_id2',
          },
        );

        test('is null when no flavor is given', () {
          expect(flavoredYaml.unknownFlavorError(null), isNull);
          expect(
            const ShorebirdYaml(appId: 'test_app_id').unknownFlavorError(null),
            isNull,
          );
        });

        test('is null for a defined flavor', () {
          expect(flavoredYaml.unknownFlavorError('production'), isNull);
        });

        test('lists the defined flavors for an unknown flavor', () {
          expect(
            flavoredYaml.unknownFlavorError('staging'),
            equals(
              'This project does not have a flavor named "staging". Pass one '
              'of: development, production (from "flavors" in '
              'shorebird.yaml).',
            ),
          );
        });

        test('explains when the project has no flavors', () {
          expect(
            const ShorebirdYaml(
              appId: 'test_app_id',
            ).unknownFlavorError('staging'),
            contains('does not have any flavors defined'),
          );
        });
      });
    });
  });
}
