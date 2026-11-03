// Host end-to-end stages of the iOS ios-aot-link route through the real CLI
// code: IosReleaser.assembleAotLinkSupplement, a zip/extract round trip of the
// supplement, IosPatcher.withAotLinkBuild / createAotLinkPatchArtifacts, the
// real ios_linker (link --min-link-percent, check, diff-base) and the real
// `patch` binary for the bidiff+zstd download. flutter_tools stages run in
// between (see tools/ios_linker/scripts/run_cli_e2e.py). Skipped unless
// SHOREBIRD_AOT_LINK_E2E names the JSON config.
//
// Config keys: stage (release|patch), work, project, dill, tool, dart,
// patch_tool, and for patches the supplement dir and the flutter patch stage
// output (patch.build.json).
@Timeout(Duration(minutes: 20))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:io' as io;

import 'package:crypto/crypto.dart';
import 'package:mocktail/mocktail.dart';
import 'package:open_aot_patch_tools/open_aot_patch_tools.dart';
import 'package:path/path.dart' as p;
import 'package:platform/testing.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/commands/patch/patch.dart';
import 'package:shorebird_cli/src/commands/release/release.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/executables/ios_linker.dart';
import 'package:shorebird_cli/src/archive/archive.dart';
import 'package:shorebird_cli/src/ios_aot_link.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform.dart' as cli_platform;
import 'package:shorebird_cli/src/platform/platform.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';
import 'package:test/test.dart';

import '../src/mocks.dart';

/// Real zip extraction; the diff is made by the real `patch` binary.
class _E2eArtifactManager extends ArtifactManager {
  _E2eArtifactManager(this.patchTool);
  final String patchTool;

  @override
  Future<String> createDiff({
    required String releaseArtifactPath,
    required String patchArtifactPath,
  }) async {
    final out = p.join(
      Directory.systemTemp.createTempSync('e2e_diff').path,
      'diff.patch',
    );
    final r = Process.runSync(patchTool, [
      releaseArtifactPath,
      patchArtifactPath,
      out,
    ]);
    if (r.exitCode != 0) throw Exception('patch failed: ${r.stderr}');
    return out;
  }
}

void main() {
  final configPath = io.Platform.environment['SHOREBIRD_AOT_LINK_E2E'];
  test(
    'ios-aot-link host end-to-end',
    () async {
      final config =
          jsonDecode(File(configPath!).readAsStringSync())
              as Map<String, dynamic>;
      final stage = config['stage'] as String;
      final work = config['work'] as String;
      final project = Directory(config['project'] as String);
      final logger = MockShorebirdLogger();
      final progress = MockProgress();
      when(() => logger.progress(any())).thenReturn(progress);
      when(() => logger.err(any())).thenAnswer((i) {
        stderr.writeln('ERR ${i.positionalArguments.first}');
      });
      when(() => logger.warn(any())).thenAnswer((i) {
        stdout.writeln('WARN ${i.positionalArguments.first}');
      });
      final shorebirdEnv = MockShorebirdEnv();
      when(() => shorebirdEnv.getShorebirdProjectRoot()).thenReturn(project);
      when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(
        const ShorebirdYaml(
          appId: 'e2e-app',
          aotPatchRuntimeMode: runtimeModeIosAotLink,
        ),
      );
      when(
        () => shorebirdEnv.dartBinaryFile,
      ).thenReturn(File(config['dart'] as String));
      when(() => shorebirdEnv.iosPodfileLockHash).thenReturn(null);
      final platform = TestNativePlatform(
        environment: {iosLinkerEnvVar: config['tool'] as String},
      );
      final artifactManager = _E2eArtifactManager(
        config['patch_tool'] as String,
      );
      final artifactBuilder = MockArtifactBuilder();
      var buildEnv = <String, String>{};
      when(
        () => artifactBuilder.iosInterpreterBuildEnvironment,
      ).thenAnswer((_) => buildEnv);
      when(
        () => artifactBuilder.iosInterpreterBuildEnvironment = any(),
      ).thenAnswer((i) {
        buildEnv = i.positionalArguments.single as Map<String, String>;
        return buildEnv;
      });

      Future<R> scopedWith<R>(
        ArtifactManager manager,
        Future<R> Function() body,
      ) async => runScoped(
        body,
        values: {
          artifactBuilderRef.overrideWith(() => artifactBuilder),
          artifactManagerRef.overrideWith(() => manager),
          iosLinkerRef.overrideWith(IosLinker.new),
          loggerRef.overrideWith(() => logger),
          cli_platform.platformRef.overrideWith(() => platform),
          processRef.overrideWith(ShorebirdProcess.new),
          shorebirdEnvRef.overrideWith(() => shorebirdEnv),
        },
      );

      Future<R> scoped<R>(Future<R> Function() body) =>
          scopedWith(artifactManager, body);

      final argResults = MockArgResults();
      when(() => argResults.rest).thenReturn([]);
      when(() => argResults.options).thenReturn([]);
      when(() => argResults.wasParsed(any())).thenReturn(false);
      when(() => argResults[any()]).thenReturn(null);

      if (stage == 'release') {
        // What flutter_tools' release stage left behind, laid out as a build.
        final built =
            jsonDecode(
                  File(p.join(work, 'release.build.json')).readAsStringSync(),
                )
                as Map<String, dynamic>;
        final sidecars = Directory(
          p.join(project.path, 'build', 'ios', 'shorebird'),
        )..createSync(recursive: true);
        for (final name in ['App.link', 'App.dd']) {
          final src = File(p.join(built['sidecar_dir'] as String, name));
          if (src.existsSync()) src.copySync(p.join(sidecars.path, name));
        }
        final app = Directory(
          p.join(work, 'xcarchive', 'Products', 'Applications', 'Runner.app'),
        );
        File(p.join(app.path, 'Frameworks', 'App.framework', 'App'))
          ..createSync(recursive: true)
          ..writeAsBytesSync(
            File(built['framework'] as String).readAsBytesSync(),
          );
        final xcarchive = Directory(p.join(work, 'xcarchive'));
        final mockManager = MockArtifactManager();
        when(mockManager.getXcarchiveDirectory).thenReturn(xcarchive);
        when(
          () => mockManager.getIosAppDirectory(
            xcarchiveDirectory: any(named: 'xcarchiveDirectory'),
          ),
        ).thenReturn(app);

        final ddBytes = config['dd_max_bytes'] as int?;
        when(() => argResults.options).thenReturn(['aot-link-dd-max-bytes']);
        when(() => argResults['aot-link-dd-max-bytes']).thenReturn(
          ddBytes == null ? null : '$ddBytes',
        );
        final releaser = IosReleaser(
          argResults: argResults,
          flavor: null,
          target: null,
        )..aotLinkKernel = File(config['dill'] as String);
        final supplement = await scopedWith(
          mockManager,
          () => releaser.assembleAotLinkSupplement(),
        );
        AotLinkSupplement.stamp(
          supplement,
          releaseId: 1,
          appBuildId: '1.0.0+1',
        );

        // Upload and download: the same zip and safe extraction the CLI uses.
        final zip = await supplement.zipToTempFile(name: 'ios_supplement');
        final downloaded = Directory(p.join(work, 'downloaded_supplement'));
        if (downloaded.existsSync()) downloaded.deleteSync(recursive: true);
        downloaded.createSync(recursive: true);
        await scoped(
          () => artifactManager.extractReleaseSupplement(
            zipFile: zip,
            outputDirectory: downloaded,
          ),
        );
        final verified = AotLinkSupplement.verify(downloaded);
        File(p.join(work, 'release.cli.json')).writeAsStringSync(
          jsonEncode({
            'supplement': downloaded.path,
            'zip_bytes': zip.lengthSync(),
            'files': {
              for (final e in verified.files.entries) e.key: e.value.size,
            },
            'release_text_sha256': verified.releaseTextSha256,
            'uses_dd': verified.usesDd,
          }),
        );
        stdout.writeln(
          'release: supplement ${zip.lengthSync()} bytes zipped, '
          'text sha256 ${verified.releaseTextSha256}, dd=${verified.usesDd}',
        );
        return;
      }

      // Patch stage.
      final built =
          jsonDecode(
                File(p.join(work, 'patch.build.json')).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final buildDir = Directory(p.join(work, 'cli_build'))
        ..createSync(recursive: true);
      when(() => shorebirdEnv.buildDirectory).thenReturn(buildDir);
      when(() => shorebirdEnv.iosSupplementDirectory).thenReturn(
        Directory(built['sidecar_dir'] as String),
      );
      final patcher = IosPatcher(
        argParser: MockArgParser(),
        argResults: argResults,
        flavor: null,
        target: null,
      )..releaseSupplementDirectory = Directory(config['supplement'] as String);

      // The environment flutter_tools was given must be the one the CLI builds.
      late Map<String, String> seen;
      await scoped(
        () => patcher.withAotLinkBuild(() async {
          seen = Map.of(artifactBuilder.iosInterpreterBuildEnvironment);
        }),
      );
      expect(
        seen[AotLinkEnvironment.base],
        p.join(config['supplement'] as String, 'App.link'),
      );
      expect(seen[AotLinkEnvironment.base], config['base_link']);

      final bundles = await scoped(patcher.createAotLinkPatchArtifacts);
      final bundle = bundles[Arch.arm64]!;
      final vmcode = File(p.join(buildDir.path, 'out.vmcode'));
      final header = VmcodeHeader.readVerified(vmcode);
      expect(
        bundle.hash,
        sha256.convert(vmcode.readAsBytesSync()).toString(),
      );
      File(p.join(work, 'patch.cli.json')).writeAsStringSync(
        jsonEncode({
          'vmcode': vmcode.path,
          'diff': bundle.path,
          'diff_base': p.join(buildDir.path, 'App.diffbase'),
          'hash': bundle.hash,
          'vmcode_bytes': vmcode.lengthSync(),
          'diff_bytes': bundle.size,
          'link_percent': patcher.linkPercentage,
          'linked_code_bytes': header.linkedCodeBytes,
          'patch_code_bytes': header.patchCodeBytes,
          'release_text_sha256': header.releaseTextSha256,
        }),
      );
      stdout.writeln(
        'patch: ${patcher.linkPercentage!.toStringAsFixed(2)}% linked, '
        'vmcode ${vmcode.lengthSync()} B, download ${bundle.size} B',
      );
    },
    skip: configPath == null ? 'set SHOREBIRD_AOT_LINK_E2E to run' : false,
  );
}
