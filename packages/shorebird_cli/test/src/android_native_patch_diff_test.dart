import 'dart:io';

import 'package:archive/archive.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/archive_analysis/android_archive_differ.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/patch_diff_checker.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:test/test.dart';

import 'helpers.dart';
import 'mocks.dart';

void main() {
  useTempWorkingDirectory();
  late ShorebirdLogger logger;
  late ShorebirdEnv environment;
  late Progress progress;

  setUp(() {
    logger = MockShorebirdLogger();
    environment = MockShorebirdEnv();
    progress = MockProgress();
    when(() => logger.progress(any())).thenReturn(progress);
    when(() => environment.canAcceptUserInput).thenReturn(false);
  });

  File bundle(String path, Map<String, List<int>> entries) {
    final archive = Archive();
    for (final entry in entries.entries) {
      archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
    }
    return File(path)..writeAsBytesSync(ZipEncoder().encode(archive));
  }

  Future<DiffStatus> check(
    File release,
    File patch, {
    bool allowNative = false,
  }) => runScoped(
    () => PatchDiffChecker().confirmUnpatchableDiffsIfNecessary(
      localArchive: patch,
      releaseArchive: release,
      archiveDiffer: const AndroidArchiveDiffer(),
      allowAssetChanges: false,
      allowNativeChanges: allowNative,
    ),
    values: {
      loggerRef.overrideWith(() => logger),
      shorebirdEnvRef.overrideWith(() => environment),
    },
  );

  for (final path in [
    'base/lib/arm64-v8a/libflutter.so',
    'lib/arm64-v8a/libplugin.so',
    'jni/arm64-v8a/libplugin.so',
    'classes.jar',
    'com/example/Plugin.class',
    'feature/lib/arm64-v8a/libapp.so',
  ]) {
    test('noninteractive native $path change aborts with a warning', () async {
      final release = bundle('release.zip', {
        'base/lib/arm64-v8a/libapp.so': [1],
        path: [1],
      });
      final patch = bundle('patch.zip', {
        'base/lib/arm64-v8a/libapp.so': [2],
        path: [2],
      });
      await expectLater(
        check(release, patch),
        throwsA(isA<UnpatchableChangeException>()),
      );
      verify(
        () => logger.warn(
          'Your app contains native changes, '
          'which cannot be applied with a patch.',
        ),
      ).called(1);
      verifyNever(() => logger.confirm(any(), hint: any(named: 'hint')));
    });
  }

  for (final path in [
    'base/lib/arm64-v8a/libapp.so',
    'lib/arm64-v8a/libapp.so',
    'jni/arm64-v8a/libapp.so',
  ]) {
    test('canonical Dart-only $path updates pass', () async {
      final release = bundle('release.zip', {
        path: [1],
      });
      final patch = bundle('patch.zip', {
        path: [2],
      });
      final status = await check(release, patch);
      expect(status.hasNativeChanges, isFalse);
      expect(status.hasAssetChanges, isFalse);
      verifyNever(() => logger.warn(any()));
    });
  }

  test('explicit native override retains warning and metadata', () async {
    final release = bundle('release.zip', {
      'jni/arm64-v8a/plugin.so': [1],
    });
    final patch = bundle('patch.zip', {
      'jni/arm64-v8a/plugin.so': [2],
    });
    final status = await check(release, patch, allowNative: true);
    expect(status.hasNativeChanges, isTrue);
    verify(
      () => logger.warn(
        'Your app contains native changes, '
        'which cannot be applied with a patch.',
      ),
    ).called(1);
  });

  test('interactive cancellation stops native changes', () async {
    when(() => environment.canAcceptUserInput).thenReturn(true);
    when(
      () => logger.confirm(any(), hint: any(named: 'hint')),
    ).thenReturn(false);
    final release = bundle('release.zip', {
      'classes.jar': [1],
    });
    final patch = bundle('patch.zip', {
      'classes.jar': [2],
    });
    await expectLater(
      check(release, patch),
      throwsA(isA<UserCancelledException>()),
    );
  });

  test('invalid ZIP cannot be bypassed with the native override', () async {
    final release = bundle('release.zip', {
      'classes.jar': [1],
    });
    final patch = File('patch.zip')..writeAsStringSync('not a ZIP');
    await expectLater(
      check(release, patch, allowNative: true),
      throwsFormatException,
    );
  });
}
