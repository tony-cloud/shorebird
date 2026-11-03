import 'dart:convert';
import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:open_aot_patch_tools/open_aot_patch_tools.dart';
import 'package:path/path.dart' as p;
import 'package:platform/testing.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/executables/ios_linker.dart';
import 'package:shorebird_cli/src/ios_aot_link.dart';
import 'package:shorebird_cli/src/platform.dart' as cli_platform;
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';
import 'package:test/test.dart';

import '../helpers.dart';
import '../mocks.dart';

void main() {
  useTempWorkingDirectory();
  group(IosLinker, () {
    late ShorebirdProcess shorebirdProcess;
    late ShorebirdEnv shorebirdEnv;
    late TestNativePlatform platform;
    late IosLinker linker;

    R runWithOverrides<R>(R Function() body) => runScoped(
      body,
      values: {
        processRef.overrideWith(() => shorebirdProcess),
        shorebirdEnvRef.overrideWith(() => shorebirdEnv),
        cli_platform.platformRef.overrideWith(() => platform),
      },
    );

    void stubRun(int exitCode, {String stdout = '', String stderr = ''}) {
      when(
        () => shorebirdProcess.run(
          any(),
          any(),
          runInShell: any(named: 'runInShell'),
          useVendedFlutter: any(named: 'useVendedFlutter'),
        ),
      ).thenAnswer(
        (_) async => ShorebirdProcessResult(
          exitCode: exitCode,
          stdout: stdout,
          stderr: stderr,
        ),
      );
    }

    setUp(() {
      shorebirdProcess = MockShorebirdProcess();
      shorebirdEnv = MockShorebirdEnv();
      platform = TestNativePlatform(
        environment: {iosLinkerEnvVar: '/tools/ios_linker.dart'},
      );
      when(
        () => shorebirdEnv.dartBinaryFile,
      ).thenReturn(File('/flutter/bin/dart'));
      linker = IosLinker();
    });

    test(
      'runs a .dart tool with the vended Dart and others directly',
      () async {
        stubRun(
          0,
          stdout: '{"format":"macho","text_size":8,"text_sha256":"ab"}',
        );
        final info = await runWithOverrides(() => linker.info(base: 'App'));
        expect(info.textSha256, 'ab');
        verify(
          () => shorebirdProcess.run(
            '/flutter/bin/dart',
            ['/tools/ios_linker.dart', 'info', '--base', 'App'],
            runInShell: false,
            useVendedFlutter: false,
          ),
        ).called(1);

        platform = platform.copyWith(
          environment: {iosLinkerEnvVar: '/tools/ios_linker'},
        );
        await runWithOverrides(
          () => linker.info(base: 'App', baseLink: 'App.link'),
        );
        verify(
          () => shorebirdProcess.run(
            '/tools/ios_linker',
            ['info', '--base', 'App', '--link', 'App.link'],
            runInShell: false,
            useVendedFlutter: false,
          ),
        ).called(1);
      },
    );

    test('link passes the gate and reads the report', () async {
      final report = File(p.join(Directory.current.path, 'report.json'))
        ..writeAsStringSync(
          jsonEncode({
            'link_percent': 91.5,
            'patch_code_bytes': 1000,
            'linked_code_bytes': 915,
            'unlinked_entries': 3,
          }),
        );
      stubRun(0);
      final result = await runWithOverrides(
        () => linker.link(
          base: 'App',
          baseLink: 'App.link',
          patchElf: 'out.aot',
          patchLink: 'out.link',
          outVmcode: 'out.vmcode',
          reportPath: report.path,
          minLinkPercent: 20,
        ),
      );
      expect(result.linkPercent, 91.5);
      verify(
        () => shorebirdProcess.run(
          '/flutter/bin/dart',
          [
            '/tools/ios_linker.dart',
            'link',
            '--base',
            'App',
            '--base-link',
            'App.link',
            '--patch-elf',
            'out.aot',
            '--patch-link',
            'out.link',
            '--out',
            'out.vmcode',
            '--report',
            report.path,
            '--min-link-percent',
            '20',
          ],
          runInShell: false,
          useVendedFlutter: false,
        ),
      ).called(1);
    });

    for (final entry in {
      1: IosLinkerFailure.checkFailed,
      2: IosLinkerFailure.unlinkedStub,
      3: IosLinkerFailure.belowMinimum,
      4: IosLinkerFailure.sidecarMismatch,
    }.entries) {
      test('exit code ${entry.key} is ${entry.value.name}', () async {
        stubRun(entry.key, stderr: 'link: detail');
        await expectLater(
          () => runWithOverrides(
            () => linker.diffBase(base: 'App', baseLink: 'App.link', out: 'o'),
          ),
          throwsA(
            isA<IosLinkerException>()
                .having((e) => e.failure, 'failure', entry.value)
                .having((e) => e.message, 'message', contains('link: detail')),
          ),
        );
      });
    }

    test('an unknown exit code keeps the tool output', () async {
      stubRun(70, stderr: 'boom');
      await expectLater(
        () => runWithOverrides(
          () => linker.diffBase(base: 'App', baseLink: 'App.link', out: 'o'),
        ),
        throwsA(
          isA<IosLinkerException>()
              .having((e) => e.failure, 'failure', isNull)
              .having(
                (e) => e.message,
                'message',
                allOf(contains('70'), contains('boom')),
              ),
        ),
      );
    });

    test('an unset tool is a clear StateError', () {
      platform = platform.copyWith(environment: {});
      expect(
        () => runWithOverrides(() => linker.requireToolPath()),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'm',
            contains(iosLinkerEnvVar),
          ),
        ),
      );
    });
  });

  group('appOwnPackages', () {
    test('keeps the app, its path dependencies and in-tree packages only', () {
      final root = Directory.systemTemp.createTempSync('own_packages');
      addTearDown(() => root.deleteSync(recursive: true));
      File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: my_app
dependencies:
  flutter:
    sdk: flutter
  sibling:
    path: ../sibling
  hosted_pkg: ^1.0.0
''');
      Directory(p.join(root.path, '.dart_tool')).createSync();
      File(
        p.join(root.path, '.dart_tool', 'package_config.json'),
      ).writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'my_app', 'rootUri': '../', 'packageUri': 'lib/'},
            {
              'name': 'inner',
              'rootUri': '../packages/inner',
              'packageUri': 'lib/',
            },
            {
              'name': 'sibling',
              'rootUri': '../../sibling',
              'packageUri': 'lib/',
            },
            {
              'name': 'hosted_pkg',
              'rootUri':
                  'file:///home/u/.pub-cache/hosted/pub.dev/hosted_pkg-1.0.0',
              'packageUri': 'lib/',
            },
            {
              'name': 'flutter',
              'rootUri': 'file:///sdk/flutter/packages/flutter',
            },
          ],
        }),
      );
      expect(appOwnPackages(root), ['inner', 'my_app', 'sibling']);
    });
  });
}
