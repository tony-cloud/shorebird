import 'dart:io';

import 'package:args/args.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/commands/patch/macos_patcher.dart';
import 'package:shorebird_cli/src/commands/release/macos_releaser.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/doctor.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform/apple/plist.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_validator.dart';
import 'package:shorebird_cli/src/validators/validators.dart';
import 'package:test/test.dart';

import '../helpers.dart';
import '../mocks.dart';

void main() {
  useTempWorkingDirectory();
  group(MacosEntitlementsValidator, () {
    const forbidden = [
      'com.apple.security.cs.allow-jit',
      'com.apple.security.cs.allow-unsigned-executable-memory',
      'com.apple.security.cs.disable-executable-page-protection',
      'com.apple.security.cs.disable-library-validation',
      'com.apple.security.cs.allow-dyld-environment-variables',
      'com.apple.security.cs.debugger',
      'com.apple.security.get-task-allow',
      'get-task-allow',
    ];
    const interpreterPolicy = ShorebirdYaml(
      appId: 'app',
      aotPatchRuntimeMode: 'dart-bytecode-interpreter',
      aotPatchFullReplacement: true,
    );
    const entitlementsPlistWithoutEntitlements = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
</dict>
</plist>
''';

    const entitlementsPlistWithAllEntitlements = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.cs.allow-unsigned-executable-memory</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
</dict>
</plist>
''';

    late Directory projectRoot;
    late ShorebirdEnv shorebirdEnv;
    late MacosEntitlementsValidator validator;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        body,
        values: {shorebirdEnvRef.overrideWith(() => shorebirdEnv)},
      );
    }

    File releaseEntitlementsFile() => File(
      p.join(projectRoot.path, 'macos', 'Runner', 'Release.entitlements'),
    );

    void setUpProjectRoot({String? entitlements}) {
      Directory(
        p.join(projectRoot.path, 'macos', 'Runner'),
      ).createSync(recursive: true);

      if (entitlements != null) {
        releaseEntitlementsFile()
          ..createSync(recursive: true)
          ..writeAsStringSync(entitlements);
      }
    }

    void writeEntitlements(Map<String, Object> values) {
      setUpProjectRoot(entitlements: entitlementsPlistWithoutEntitlements);
      final plist = Plist(file: releaseEntitlementsFile());
      plist.properties.addAll(values);
      releaseEntitlementsFile().writeAsStringSync(plist.toString());
    }

    setUp(() {
      projectRoot = Directory.systemTemp.createTempSync();
      final ownedProjectRoot = projectRoot;
      addTearDown(() => ownedProjectRoot.deleteSync(recursive: true));
      shorebirdEnv = MockShorebirdEnv();

      when(() => shorebirdEnv.getFlutterProjectRoot()).thenReturn(projectRoot);

      validator = MacosEntitlementsValidator();
    });

    group('data-only interpreter policy', () {
      setUp(() {
        when(
          () => shorebirdEnv.getShorebirdYaml(),
        ).thenReturn(interpreterPolicy);
      });

      test(
        'requires network only and never offers an executable-memory fix',
        () async {
          writeEntitlements({});
          final issues = await runWithOverrides(validator.validate);
          expect(issues, hasLength(1));
          expect(issues.single.message, contains('Outgoing Connections'));
          await runWithOverrides(issues.single.fix!);
          final properties = Plist(file: releaseEntitlementsFile()).properties;
          expect(
            properties[MacosEntitlementsValidator.networkClientEntitlementKey],
            isTrue,
          );
          for (final key in forbidden) {
            expect(properties, isNot(contains(key)));
          }
          expect(await runWithOverrides(validator.validate), isEmpty);
        },
      );

      test(
        'absent and Boolean false grants are disabled; other types fail closed',
        () async {
          writeEntitlements({
            MacosEntitlementsValidator.networkClientEntitlementKey: true,
            for (final key in forbidden) key: false,
          });
          expect(await runWithOverrides(validator.validate), isEmpty);
          for (final value in [true, 'true', 'false', 0, 1]) {
            for (final key in forbidden) {
              writeEntitlements({
                MacosEntitlementsValidator.networkClientEntitlementKey: true,
                key: value,
              });
              final issues = await runWithOverrides(validator.validate);
              expect(issues, hasLength(1), reason: '$key=$value');
              expect(issues.single.severity, ValidationIssueSeverity.error);
              expect(issues.single.message, contains(key));
              expect(issues.single.fix, isNull);
            }
          }
        },
      );

      test(
        'incomplete interpreter configuration cannot receive native fixes',
        () async {
          when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(
            const ShorebirdYaml(
              appId: 'app',
              aotPatchRuntimeMode: 'dart-bytecode-interpreter',
            ),
          );
          writeEntitlements({
            MacosEntitlementsValidator.networkClientEntitlementKey: true,
          });
          expect(await runWithOverrides(validator.validate), isEmpty);
        },
      );
    });

    test('native policy and executable-memory fix remain unchanged', () async {
      when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(
        const ShorebirdYaml(
          appId: 'app',
          aotPatchRuntimeMode: 'native-aot',
        ),
      );
      writeEntitlements({
        MacosEntitlementsValidator.networkClientEntitlementKey: true,
      });
      final issues = await runWithOverrides(validator.validate);
      expect(issues, hasLength(1));
      expect(
        issues.single.message,
        contains('Allow Unsigned Executable Memory'),
      );
      await runWithOverrides(issues.single.fix!);
      expect(await runWithOverrides(validator.validate), isEmpty);
    });

    test(
      'a stale native doctor fix cannot enable memory after YAML mode changes',
      () async {
        writeEntitlements({
          MacosEntitlementsValidator.networkClientEntitlementKey: true,
        });
        final nativeIssues = await runWithOverrides(validator.validate);
        expect(nativeIssues, hasLength(1));
        when(
          () => shorebirdEnv.getShorebirdYaml(),
        ).thenReturn(interpreterPolicy);
        expect(
          () => runWithOverrides(nativeIssues.single.fix!),
          throwsException,
        );
        expect(
          Plist(file: releaseEntitlementsFile()).properties,
          isNot(
            contains(
              MacosEntitlementsValidator.allowUnsignedExecutableMemoryKey,
            ),
          ),
        );
      },
    );

    test(
      'real YAML selects strict validators for release, patch and doctor fix',
      () async {
        // useTempWorkingDirectory supplies an isolate-local working directory.
        projectRoot = Directory.current;
        File('shorebird.yaml').writeAsStringSync('''
app_id: app
aot_patch_runtime_mode: dart-bytecode-interpreter
aot_patch_full_replacement: true
''');
        shorebirdEnv = ShorebirdEnv(
          flutterProjectRootOverride: projectRoot.path,
        );
        final actualDoctor = Doctor();
        final logger = MockShorebirdLogger();
        when(() => logger.progress(any())).thenReturn(MockProgress());
        final args = MockArgResults();
        final release = MacosReleaser(
          argResults: args,
          flavor: null,
          target: null,
        );
        final patch = MacosPatcher(
          argParser: ArgParser(),
          argResults: args,
          flavor: null,
          target: null,
        );
        await runScoped(
          () async {
            final selections = [
              release.applePlatformValidators,
              patch.applePlatformValidators,
              actualDoctor.initAndDoctorValidators
                  .whereType<MacosEntitlementsValidator>()
                  .toList(),
            ];
            const preflight = ShorebirdValidator();
            for (final selected in selections) {
              writeEntitlements({
                MacosEntitlementsValidator.networkClientEntitlementKey: true,
              });
              await preflight.validatePreconditions(
                validators: selected,
              );
              writeEntitlements({
                MacosEntitlementsValidator.networkClientEntitlementKey: true,
                MacosEntitlementsValidator.allowUnsignedExecutableMemoryKey:
                    true,
              });
              await expectLater(
                preflight.validatePreconditions(
                  validators: selected,
                ),
                throwsA(isA<ValidationFailedException>()),
              );
              writeEntitlements({});
              await actualDoctor.runValidators(selected, applyFixes: true);
              final properties = Plist(
                file: releaseEntitlementsFile(),
              ).properties;
              expect(
                properties[MacosEntitlementsValidator
                    .networkClientEntitlementKey],
                isTrue,
              );
              for (final key in forbidden) {
                expect(properties, isNot(contains(key)));
              }
              expect((await actualDoctor.validate(selected)).single.ok, isTrue);
            }
          },
          values: {
            shorebirdEnvRef.overrideWith(() => shorebirdEnv),
            doctorRef.overrideWith(() => actualDoctor),
            loggerRef.overrideWith(() => logger),
          },
        );
      },
    );

    group('description', () {
      test('returns the correct description', () {
        expect(
          runWithOverrides(() => validator.description),
          'macOS app has correct entitlements',
        );
      });
    });

    group('canRunInCurrentContext', () {
      group('when macos directory exists', () {
        setUp(setUpProjectRoot);

        test('returns true', () {
          expect(
            runWithOverrides(() => validator.canRunInCurrentContext()),
            isTrue,
          );
        });
      });

      group('when macos directory does not exist', () {
        test('returns false', () {
          expect(
            runWithOverrides(() => validator.canRunInCurrentContext()),
            isFalse,
          );
          expect(
            runWithOverrides(() => validator.incorrectContextMessage),
            contains(
              '''The command you are running must be run within a Flutter app project that supports the macOS platform.''',
            ),
          );
        });
      });
    });

    group('validate', () {
      group('when release entitlements plist does not exist', () {
        setUp(setUpProjectRoot);

        test('returns a validation issue with no fix', () async {
          final issues = await runWithOverrides(() => validator.validate());
          expect(issues, hasLength(1));
          expect(
            issues[0],
            equals(
              const ValidationIssue(
                severity: ValidationIssueSeverity.error,
                message: 'Unable to find a Release.entitlements file',
              ),
            ),
          );
        });
      });

      group('when release entitlements plist exists', () {
        group('when entitlements are missing', () {
          setUp(() {
            setUpProjectRoot(
              entitlements: entitlementsPlistWithoutEntitlements,
            );
          });

          test('returns validation issues with fixes', () async {
            final validationResults = await runWithOverrides(
              () => validator.validate(),
            );
            expect(validationResults, hasLength(2));
            final networkIssue = validationResults[0];
            expect(networkIssue.severity, ValidationIssueSeverity.error);
            expect(
              networkIssue.message,
              contains(
                '''is missing the Outgoing Connections (com.apple.security.network.client) entitlement.''',
              ),
            );
            expect(networkIssue.fix, isNotNull);
            expect(
              MacosEntitlementsValidator.hasEntitlement(
                plistFile: releaseEntitlementsFile(),
                key: MacosEntitlementsValidator.networkClientEntitlementKey,
              ),
              isFalse,
            );
            runWithOverrides(() => networkIssue.fix!());
            expect(
              MacosEntitlementsValidator.hasEntitlement(
                plistFile: releaseEntitlementsFile(),
                key: MacosEntitlementsValidator.networkClientEntitlementKey,
              ),
              isTrue,
            );

            final unsignedMemoryIssue = validationResults[1];
            expect(unsignedMemoryIssue.severity, ValidationIssueSeverity.error);
            expect(
              unsignedMemoryIssue.message,
              contains(
                '''is missing the Allow Unsigned Executable Memory (com.apple.security.cs.allow-unsigned-executable-memory) entitlement.''',
              ),
            );
            expect(unsignedMemoryIssue.fix, isNotNull);
            expect(
              MacosEntitlementsValidator.hasEntitlement(
                plistFile: releaseEntitlementsFile(),
                key:
                    MacosEntitlementsValidator.allowUnsignedExecutableMemoryKey,
              ),
              isFalse,
            );
            runWithOverrides(() => unsignedMemoryIssue.fix!());
            expect(
              MacosEntitlementsValidator.hasEntitlement(
                plistFile: releaseEntitlementsFile(),
                key:
                    MacosEntitlementsValidator.allowUnsignedExecutableMemoryKey,
              ),
              isTrue,
            );
          });
        });

        group('when entitlements are present', () {
          setUp(() {
            setUpProjectRoot(
              entitlements: entitlementsPlistWithAllEntitlements,
            );
          });

          test('returns an empty list', () async {
            expect(await runWithOverrides(() => validator.validate()), isEmpty);
          });
        });
      });
    });
  });
}
