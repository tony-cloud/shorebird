import 'dart:convert';

import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/metadata/metadata.dart';
import 'package:test/test.dart';
import '../helpers.dart';

void main() {
  useTempWorkingDirectory();
  group(BuildEnvironmentMetadata, () {
    test('can be (de)serialized', () {
      const metadata = BuildEnvironmentMetadata(
        flutterRevision: '853d13d954df3b6e9c2f07b72062f33c52a9a64b',
        operatingSystem: 'macos',
        operatingSystemVersion: '1.2.3',
        shorebirdVersion: '4.5.6',
        shorebirdYaml: ShorebirdYaml(appId: 'app-id'),
        usesShorebirdCodePushPackage: false,
        xcodeVersion: '15.0',
      );
      expect(
        BuildEnvironmentMetadata.fromJson(metadata.toJson()).toJson(),
        equals(metadata.toJson()),
      );
    });

    test('uploaded JSON excludes local secrets without mutating config', () {
      const secret = 'development-only-aes-key';
      final yaml = ShorebirdYaml.fromJson({
        'app_id': 'app-id',
        'aot_patch_key_hex': secret,
        'aot_patch_key_id': 'public-key-id',
        'aot_patch_bytecode_path': '/local/private/patch.bytecode',
      });
      final metadata = BuildEnvironmentMetadata.forTest(shorebirdYaml: yaml);
      final uploaded = jsonEncode(metadata.toJson());
      final uploadedYaml =
          (jsonDecode(uploaded) as Map)['shorebird_yaml'] as Map;
      expect(uploaded, isNot(contains(secret)));
      expect(uploadedYaml, isNot(contains('aot_patch_key_hex')));
      expect(uploadedYaml, isNot(contains('aot_patch_bytecode_path')));
      expect(uploadedYaml['aot_patch_key_id'], 'public-key-id');
      expect(yaml.aotPatchKeyHex, secret);
      expect(yaml.toJson()['aot_patch_key_hex'], secret);
    });

    group('copyWith', () {
      test('creates a copy with the same fields', () {
        const metadata = BuildEnvironmentMetadata(
          flutterRevision: '853d13d954df3b6e9c2f07b72062f33c52a9a64b',
          operatingSystem: 'macos',
          operatingSystemVersion: '1.2.3',
          shorebirdVersion: '4.5.6',
          shorebirdYaml: ShorebirdYaml(appId: 'app-id'),
          usesShorebirdCodePushPackage: false,
          xcodeVersion: '15.0',
        );

        expect(metadata.copyWith(), equals(metadata));
      });

      test('returns a new instance with the given fields replaced', () {
        const metadata = BuildEnvironmentMetadata(
          flutterRevision: '853d13d954df3b6e9c2f07b72062f33c52a9a64b',
          operatingSystem: 'macos',
          operatingSystemVersion: '1.2.3',
          shorebirdVersion: '4.5.6',
          shorebirdYaml: ShorebirdYaml(appId: 'app-id'),
          usesShorebirdCodePushPackage: false,
          xcodeVersion: '15.0',
        );
        final newMetadata = metadata.copyWith(
          flutterRevision: 'asdf',
          operatingSystem: 'windows',
          operatingSystemVersion: '11',
          shorebirdVersion: '1.2.3',
          shorebirdYaml: const ShorebirdYaml(appId: 'app-id2'),
          usesShorebirdCodePushPackage: true,
          xcodeVersion: '14.0',
        );
        expect(
          newMetadata,
          equals(
            const BuildEnvironmentMetadata(
              flutterRevision: 'asdf',
              operatingSystem: 'windows',
              operatingSystemVersion: '11',
              shorebirdVersion: '1.2.3',
              shorebirdYaml: ShorebirdYaml(appId: 'app-id2'),
              usesShorebirdCodePushPackage: true,
              xcodeVersion: '14.0',
            ),
          ),
        );
      });
    });

    group('equatable', () {
      test('two metadatas with the same properties are equal', () {
        const metadata = BuildEnvironmentMetadata(
          flutterRevision: '853d13d954df3b6e9c2f07b72062f33c52a9a64b',
          operatingSystem: 'macos',
          operatingSystemVersion: '1.2.3',
          shorebirdVersion: '4.5.6',
          shorebirdYaml: ShorebirdYaml(appId: 'app-id'),
          usesShorebirdCodePushPackage: true,
          xcodeVersion: '15.0',
        );
        const otherMetadata = BuildEnvironmentMetadata(
          flutterRevision: '853d13d954df3b6e9c2f07b72062f33c52a9a64b',
          operatingSystem: 'macos',
          operatingSystemVersion: '1.2.3',
          shorebirdVersion: '4.5.6',
          shorebirdYaml: ShorebirdYaml(appId: 'app-id'),
          usesShorebirdCodePushPackage: true,
          xcodeVersion: '15.0',
        );
        expect(metadata, equals(otherMetadata));
      });

      test('two metadatas with different properties are not equal', () {
        const metadata = BuildEnvironmentMetadata(
          flutterRevision: '853d13d954df3b6e9c2f07b72062f33c52a9a64b',
          operatingSystem: 'macos',
          operatingSystemVersion: '1.2.3',
          shorebirdVersion: '4.5.6',
          shorebirdYaml: ShorebirdYaml(appId: 'app-id'),
          usesShorebirdCodePushPackage: true,
          xcodeVersion: '15.0',
        );
        const otherMetadata = BuildEnvironmentMetadata(
          flutterRevision: '853d13d954df3b6e9c2f07b72062f33c52a9a64b',
          operatingSystem: 'macos',
          operatingSystemVersion: '1.2.3',
          shorebirdVersion: '4.5.6',
          shorebirdYaml: ShorebirdYaml(appId: 'app-id2'),
          usesShorebirdCodePushPackage: true,
          xcodeVersion: '15.1',
        );
        expect(metadata, isNot(equals(otherMetadata)));
      });
    });
  });
}
