import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:open_aot_patch_tools/open_aot_patch_tools.dart';
import 'package:path/path.dart' as p;
import 'package:platform/testing.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/commands/patch/patch.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/executables/ios_linker.dart';
import 'package:shorebird_cli/src/ios_aot_link.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform.dart' as cli_platform;
import 'package:shorebird_cli/src/platform/platform.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:test/test.dart';

import '../../fakes.dart';
import '../../helpers.dart';
import '../../mocks.dart';

const _head =
    '#osb-link-info 2\n'
    'id\tsnapshot_hash\taaaa\n'
    'id\tfeatures\tproduct arm64 ios\n'
    'meta\ttext_image_size\t4096\n';

Uint8List _vmcode({required String releaseTextSha256, int linked = 95}) {
  final elf = [1, 2, 3, 4];
  final out = Uint8List(16384 + elf.length);
  ByteData.sublistView(out)
    ..setUint32(8, 1, Endian.little)
    ..setUint32(12, 16384, Endian.little)
    ..setUint64(16, 16384, Endian.little)
    ..setUint64(24, elf.length, Endian.little)
    ..setUint32(36, 16, Endian.little)
    ..setUint32(40, 128, Endian.little)
    ..setUint32(112, 4096, Endian.little)
    ..setUint32(116, 4096, Endian.little)
    ..setUint32(120, linked, Endian.little)
    ..setUint32(124, 100, Endian.little);
  out
    ..setAll(0, VmcodeHeader.magic)
    ..setAll(
      48,
      List.generate(
        32,
        (i) =>
            int.parse(releaseTextSha256.substring(i * 2, i * 2 + 2), radix: 16),
      ),
    )
    ..setAll(80, sha256.convert(elf).bytes)
    ..setAll(16384, elf);
  return out;
}

void main() {
  useTempWorkingDirectory();
  group('IosAotLinkPatcherMixin', () {
    final textSha = sha256.convert(utf8.encode('release text')).toString();
    late ArgParser argParser;
    late ArgResults argResults;
    late ArtifactBuilder artifactBuilder;
    late ArtifactManager artifactManager;
    late IosLinker iosLinker;
    late ShorebirdLogger logger;
    late Progress progress;
    late ShorebirdEnv shorebirdEnv;
    late TestNativePlatform platform;
    late Directory projectRoot;
    late Directory supplement;
    late Directory buildDir;
    late IosPatcher patcher;
    late Map<String, String> parsed;

    R runWithOverrides<R>(R Function() body) => runScoped(
      body,
      values: {
        artifactBuilderRef.overrideWith(() => artifactBuilder),
        artifactManagerRef.overrideWith(() => artifactManager),
        iosLinkerRef.overrideWith(() => iosLinker),
        loggerRef.overrideWith(() => logger),
        cli_platform.platformRef.overrideWith(() => platform),
        shorebirdEnvRef.overrideWith(() => shorebirdEnv),
      },
    );

    setUpAll(() {
      registerFallbackValue(FakeArgResults());
    });

    setUp(() {
      parsed = {};
      argParser = MockArgParser();
      argResults = MockArgResults();
      artifactBuilder = MockArtifactBuilder();
      artifactManager = MockArtifactManager();
      iosLinker = MockIosLinker();
      logger = MockShorebirdLogger();
      progress = MockProgress();
      shorebirdEnv = MockShorebirdEnv();
      platform = TestNativePlatform(environment: {});
      projectRoot = Directory.systemTemp.createTempSync();
      buildDir = Directory(p.join(projectRoot.path, 'build'))
        ..createSync(recursive: true);
      supplement = Directory.systemTemp.createTempSync();

      var env = <String, String>{};
      when(() => artifactBuilder.iosInterpreterBuildEnvironment).thenAnswer(
        (_) => env,
      );
      when(
        () => artifactBuilder.iosInterpreterBuildEnvironment = any(),
      ).thenAnswer((i) {
        env = i.positionalArguments.single as Map<String, String>;
        return env;
      });
      when(() => argParser.options).thenReturn({});
      when(() => argResults.options).thenReturn(
        [
          'min-link-percentage',
          'warn-link-percentage',
        ],
      );
      when(() => argResults.rest).thenReturn([]);
      when(() => argResults.wasParsed(any())).thenAnswer(
        (i) => parsed.containsKey(i.positionalArguments.single),
      );
      when(() => argResults[any()]).thenAnswer(
        (i) => parsed[i.positionalArguments.single as String],
      );
      when(() => logger.progress(any())).thenReturn(progress);
      when(
        () => shorebirdEnv.getShorebirdProjectRoot(),
      ).thenReturn(projectRoot);
      when(() => shorebirdEnv.buildDirectory).thenReturn(buildDir);
      when(() => shorebirdEnv.iosSupplementDirectory).thenReturn(
        Directory(p.join(buildDir.path, 'ios', 'shorebird')),
      );
      when(() => shorebirdEnv.iosPodfileLockHash).thenReturn(null);
      when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(
        const ShorebirdYaml(
          appId: 'app',
          aotPatchRuntimeMode: runtimeModeIosAotLink,
        ),
      );
      when(() => iosLinker.toolPath).thenReturn('/tools/ios_linker.dart');
      when(
        () => iosLinker.requireToolPath(),
      ).thenReturn('/tools/ios_linker.dart');

      // A verified supplement.
      File(p.join(supplement.path, 'App.link')).writeAsStringSync(_head);
      File(p.join(supplement.path, 'app.dill')).writeAsStringSync('kernel');
      File(p.join(supplement.path, 'App.macho')).writeAsStringSync('macho');
      AotLinkSupplement.write(
        supplement,
        releaseTextSha256: textSha,
        textImageSize: 4096,
      );

      // What flutter_tools leaves behind.
      final out = Directory(p.join(buildDir.path, 'ios', 'shorebird'))
        ..createSync(recursive: true);
      File(p.join(out.path, 'out.aot')).writeAsStringSync('elf');
      File(p.join(out.path, 'out.link')).writeAsStringSync(_head);

      patcher = IosPatcher(
        argParser: argParser,
        argResults: argResults,
        flavor: null,
        target: null,
      )..releaseSupplementDirectory = supplement;
    });

    void stubLinkSuccess({double percent = 95, String? vmcodeTextSha}) {
      when(
        () => iosLinker.link(
          base: any(named: 'base'),
          baseLink: any(named: 'baseLink'),
          patchElf: any(named: 'patchElf'),
          patchLink: any(named: 'patchLink'),
          outVmcode: any(named: 'outVmcode'),
          reportPath: any(named: 'reportPath'),
          minLinkPercent: any(named: 'minLinkPercent'),
        ),
      ).thenAnswer((i) async {
        File(i.namedArguments[#outVmcode] as String).writeAsBytesSync(
          _vmcode(releaseTextSha256: vmcodeTextSha ?? textSha),
        );
        return IosLinkReport(
          linkPercent: percent,
          patchCodeBytes: 100,
          linkedCodeBytes: percent.round(),
          unlinkedEntries: 7,
          json: {'unlinked_by_reason': <String, Object?>{}},
        );
      });
      when(
        () => iosLinker.check(
          vmcode: any(named: 'vmcode'),
          base: any(named: 'base'),
          patchElf: any(named: 'patchElf'),
          baseLink: any(named: 'baseLink'),
          patchLink: any(named: 'patchLink'),
          minLinkPercent: any(named: 'minLinkPercent'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => iosLinker.diffBase(
          base: any(named: 'base'),
          baseLink: any(named: 'baseLink'),
          out: any(named: 'out'),
        ),
      ).thenAnswer((i) async {
        File(i.namedArguments[#out] as String).writeAsStringSync('diffbase');
      });
      when(
        () => artifactManager.createDiff(
          releaseArtifactPath: any(named: 'releaseArtifactPath'),
          patchArtifactPath: any(named: 'patchArtifactPath'),
        ),
      ).thenAnswer((i) async {
        final diff = File(p.join(buildDir.path, 'diff.patch'))
          ..writeAsStringSync('diff');
        return diff.path;
      });
    }

    test('is selected by shorebird.yaml, not by the environment alone', () {
      expect(runWithOverrides(() => patcher.aotLinkSelected), isTrue);
      when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(
        const ShorebirdYaml(appId: 'app'),
      );
      expect(runWithOverrides(() => patcher.aotLinkSelected), isFalse);
      platform = platform.copyWith(
        environment: {'SHOREBIRD_IOS_PATCH_RUNTIME_MODE': 'ios-aot-link'},
      );
      expect(
        () => runWithOverrides(() => patcher.aotLinkSelected),
        throwsA(isA<ProcessExit>()),
      );
    });

    group('policy', () {
      test('defaults to warn below 90 and fail below 20', () {
        final policy = runWithOverrides(() => patcher.aotLinkPolicy);
        expect(policy.warnBelow, 90);
        expect(policy.failBelow, 20);
      });

      test('--min-link-percentage and --warn-link-percentage configure it', () {
        parsed = {'min-link-percentage': '35', 'warn-link-percentage': '75'};
        final policy = runWithOverrides(() => patcher.aotLinkPolicy);
        expect(policy.warnBelow, 75);
        expect(policy.failBelow, 35);
      });

      test('a default-valued --min-link-percentage does not apply', () {
        parsed = {'min-link-percentage': '0'};
        when(() => argResults.wasParsed(any())).thenReturn(false);
        expect(
          runWithOverrides(() => patcher.aotLinkPolicy.failBelow),
          20,
        );
      });

      test('rejects a failure threshold above the warning threshold', () {
        parsed = {'min-link-percentage': '95'};
        expect(
          () => runWithOverrides(() => patcher.aotLinkPolicy),
          throwsA(isA<ProcessExit>()),
        );
      });
    });

    group('withAotLinkBuild', () {
      setUp(() {
        when(
          () => iosLinker.info(
            base: any(named: 'base'),
            baseLink: any(named: 'baseLink'),
          ),
        ).thenAnswer(
          (_) async => IosSnapshotInfo(
            format: 'macho',
            textSize: 4096,
            textSha256: textSha,
          ),
        );
      });

      test(
        'points flutter_tools at the release sidecar and restores',
        () async {
          Map<String, String>? seen;
          await runWithOverrides(
            () => patcher.withAotLinkBuild(() async {
              seen = Map.of(artifactBuilder.iosInterpreterBuildEnvironment);
            }),
          );
          expect(
            seen![AotLinkEnvironment.base],
            p.join(supplement.path, 'App.link'),
          );
          expect(seen![AotLinkEnvironment.tool], '/tools/ios_linker.dart');
          expect(seen!.containsKey(AotLinkEnvironment.ddTargets), isFalse);
          expect(artifactBuilder.iosInterpreterBuildEnvironment, isEmpty);
        },
      );

      test('passes the DD targets of a DD release', () async {
        File(p.join(supplement.path, 'App.dd')).writeAsStringSync('# DD\nf\n');
        for (final f in supplement.listSync().whereType<File>().toList()) {
          if (p.basename(f.path) == AotLinkSupplement.manifestFileName)
            f.deleteSync();
        }
        AotLinkSupplement.write(
          supplement,
          releaseTextSha256: textSha,
          textImageSize: 4096,
          ddMaxBytes: 10000,
          ddPackages: ['app'],
        );
        Map<String, String>? seen;
        await runWithOverrides(
          () => patcher.withAotLinkBuild(() async {
            seen = Map.of(artifactBuilder.iosInterpreterBuildEnvironment);
          }),
        );
        expect(
          seen![AotLinkEnvironment.ddTargets],
          p.join(supplement.path, 'App.dd'),
        );
      });

      test('rejects a supplement whose binary was swapped', () async {
        File(p.join(supplement.path, 'App.macho')).writeAsStringSync('other');
        await expectLater(
          () => runWithOverrides(() => patcher.withAotLinkBuild(() async {})),
          throwsA(isA<ProcessExit>()),
        );
        verify(() => logger.err(any(that: contains('App.macho')))).called(1);
      });

      test(
        'rejects a release binary whose text hash differs from the record',
        () async {
          when(
            () => iosLinker.info(
              base: any(named: 'base'),
              baseLink: any(named: 'baseLink'),
            ),
          ).thenAnswer(
            (_) async => const IosSnapshotInfo(
              format: 'macho',
              textSize: 4096,
              textSha256: 'ff',
            ),
          );
          await expectLater(
            () => runWithOverrides(() => patcher.withAotLinkBuild(() async {})),
            throwsA(isA<ProcessExit>()),
          );
          verify(
            () => logger.err(any(that: contains('does not hash'))),
          ).called(1);
        },
      );

      test('requires the supplement and the tool', () async {
        patcher.releaseSupplementDirectory = null;
        await expectLater(
          () => runWithOverrides(() => patcher.withAotLinkBuild(() async {})),
          throwsA(isA<ProcessExit>()),
        );
        patcher.releaseSupplementDirectory = supplement;
        when(() => iosLinker.toolPath).thenReturn(null);
        await expectLater(
          () => runWithOverrides(() => patcher.withAotLinkBuild(() async {})),
          throwsA(isA<ProcessExit>()),
        );
      });
    });

    group('createAotLinkPatchArtifacts', () {
      test(
        'links, checks, diffs against the release and hashes the vmcode for signing',
        () async {
          stubLinkSuccess();
          final bundles = await runWithOverrides(
            () => patcher.createAotLinkPatchArtifacts(),
          );
          final vmcode = File(p.join(buildDir.path, 'out.vmcode'));
          final bundle = bundles[Arch.arm64]!;
          expect(bundle.arch, 'aarch64');
          expect(
            bundle.hash,
            sha256.convert(vmcode.readAsBytesSync()).toString(),
          );
          expect(bundle.size, 4);
          verify(
            () => iosLinker.link(
              base: p.join(supplement.path, 'App.macho'),
              baseLink: p.join(supplement.path, 'App.link'),
              patchElf: p.join(buildDir.path, 'ios', 'shorebird', 'out.aot'),
              patchLink: p.join(buildDir.path, 'ios', 'shorebird', 'out.link'),
              outVmcode: vmcode.path,
              reportPath: any(named: 'reportPath'),
              minLinkPercent: 20,
            ),
          ).called(1);
          verify(
            () => iosLinker.check(
              vmcode: vmcode.path,
              base: p.join(supplement.path, 'App.macho'),
              patchElf: any(named: 'patchElf'),
              baseLink: any(named: 'baseLink'),
              patchLink: any(named: 'patchLink'),
              minLinkPercent: 20,
            ),
          ).called(1);
          // The diff is against the release's data+text blob.
          verify(
            () => artifactManager.createDiff(
              releaseArtifactPath: p.join(buildDir.path, 'App.diffbase'),
              patchArtifactPath: vmcode.path,
            ),
          ).called(1);
          expect(patcher.linkPercentage, 95);
          verifyNever(() => logger.warn(any(that: contains('Only'))));
        },
      );

      test('warns below the warning threshold but still publishes', () async {
        stubLinkSuccess(percent: 60);
        final bundles = await runWithOverrides(
          () => patcher.createAotLinkPatchArtifacts(),
        );
        expect(bundles, hasLength(1));
        verify(() => logger.warn(any(that: contains('Only 60.0%')))).called(1);
      });

      test('a configured warning threshold is honoured', () async {
        parsed = {'warn-link-percentage': '50'};
        stubLinkSuccess(percent: 60);
        await runWithOverrides(() => patcher.createAotLinkPatchArtifacts());
        verifyNever(() => logger.warn(any(that: contains('Only'))));
      });

      for (final entry in {
        2: 'same Flutter engine',
        3: 'Too little of the patch',
        4: 'different gen_snapshot',
      }.entries) {
        test('maps linker exit code ${entry.key} to a clear error', () async {
          stubLinkSuccess();
          when(
            () => iosLinker.link(
              base: any(named: 'base'),
              baseLink: any(named: 'baseLink'),
              patchElf: any(named: 'patchElf'),
              patchLink: any(named: 'patchLink'),
              outVmcode: any(named: 'outVmcode'),
              reportPath: any(named: 'reportPath'),
              minLinkPercent: any(named: 'minLinkPercent'),
            ),
          ).thenThrow(
            IosLinkerException(
              command: 'link',
              exitCode: entry.key,
              output: 'tool detail',
              failBelow: 20,
            ),
          );
          await expectLater(
            () => runWithOverrides(() => patcher.createAotLinkPatchArtifacts()),
            throwsA(isA<ProcessExit>()),
          );
          verify(() => logger.err(any(that: contains(entry.value)))).called(1);
          verifyNever(
            () => artifactManager.createDiff(
              releaseArtifactPath: any(named: 'releaseArtifactPath'),
              patchArtifactPath: any(named: 'patchArtifactPath'),
            ),
          );
        });
      }

      test('a failing check stops before the diff', () async {
        stubLinkSuccess();
        when(
          () => iosLinker.check(
            vmcode: any(named: 'vmcode'),
            base: any(named: 'base'),
            patchElf: any(named: 'patchElf'),
            baseLink: any(named: 'baseLink'),
            patchLink: any(named: 'patchLink'),
            minLinkPercent: any(named: 'minLinkPercent'),
          ),
        ).thenThrow(
          const IosLinkerException(
            command: 'check',
            exitCode: 1,
            output: 'FAIL range 4',
          ),
        );
        await expectLater(
          () => runWithOverrides(() => patcher.createAotLinkPatchArtifacts()),
          throwsA(isA<ProcessExit>()),
        );
        verify(
          () => logger.err(any(that: contains('independent verification'))),
        ).called(1);
        verifyNever(
          () => iosLinker.diffBase(
            base: any(named: 'base'),
            baseLink: any(named: 'baseLink'),
            out: any(named: 'out'),
          ),
        );
      });

      test('refuses a vmcode that names another release text', () async {
        stubLinkSuccess(vmcodeTextSha: 'ab' * 32);
        await expectLater(
          () => runWithOverrides(() => patcher.createAotLinkPatchArtifacts()),
          throwsA(isA<ProcessExit>()),
        );
        verify(
          () => logger.err(any(that: contains('different release text'))),
        ).called(1);
      });

      test('refuses a missing patch ELF', () async {
        File(p.join(buildDir.path, 'ios', 'shorebird', 'out.aot')).deleteSync();
        await expectLater(
          () => runWithOverrides(() => patcher.createAotLinkPatchArtifacts()),
          throwsA(isA<ProcessExit>()),
        );
        verify(() => logger.err(any(that: contains('out.aot')))).called(1);
      });

      test('refuses a tampered supplement even after the build', () async {
        stubLinkSuccess();
        File(
          p.join(supplement.path, 'App.link'),
        ).writeAsStringSync('${_head}x\n');
        await expectLater(
          () => runWithOverrides(() => patcher.createAotLinkPatchArtifacts()),
          throwsA(isA<ProcessExit>()),
        );
        verifyNever(
          () => iosLinker.link(
            base: any(named: 'base'),
            baseLink: any(named: 'baseLink'),
            patchElf: any(named: 'patchElf'),
            patchLink: any(named: 'patchLink'),
            outVmcode: any(named: 'outVmcode'),
            reportPath: any(named: 'reportPath'),
            minLinkPercent: any(named: 'minLinkPercent'),
          ),
        );
      });
    });
  });
}
