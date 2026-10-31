import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/archive_analysis/android_archive_differ.dart';
import 'package:shorebird_cli/src/archive_analysis/bundle_dependencies.dart';
import 'package:shorebird_cli/src/archive_analysis/file_set_diff.dart';
import 'package:test/test.dart';

import '../helpers.dart';
import 'bundle_dependencies_helpers.dart';

void main() {
  useTempWorkingDirectory();
  group(AndroidArchiveDiffer, () {
    final aabFixturesBasePath = p.join(fixturesDirectory, 'aabs');
    final baseAabPath = p.join(aabFixturesBasePath, 'base.aab');
    final changedAssetAabPath = p.join(
      aabFixturesBasePath,
      'changed_asset.aab',
    );
    final changedDartAabPath = p.join(aabFixturesBasePath, 'changed_dart.aab');
    final changedKotlinAabPath = p.join(
      aabFixturesBasePath,
      'changed_kotlin.aab',
    );
    final changedDartAndAssetAabPath = p.join(
      aabFixturesBasePath,
      'changed_dart_and_asset.aab',
    );

    final aarFixturesBasePath = p.join(fixturesDirectory, 'aars');
    final baseAarPath = p.join(aarFixturesBasePath, 'base.aar');
    final changedAssetAarPath = p.join(
      aarFixturesBasePath,
      'changed_asset.aar',
    );
    final changedDartAarPath = p.join(aarFixturesBasePath, 'changed_dart.aar');
    final changedDartAndAssetAarPath = p.join(
      aarFixturesBasePath,
      'changed_dart_and_asset.aar',
    );

    late AndroidArchiveDiffer differ;

    setUp(() {
      differ = const AndroidArchiveDiffer();
    });

    test('generated Flutter AARs contain immutable Java bytecode', () {
      final archive = ZipDecoder().decodeBytes(
        File(baseAarPath).readAsBytesSync(),
      );
      expect(archive.findFile('classes.jar'), isNotNull);
      expect(differ.isNativeFilePath('classes.jar'), isTrue);
    });

    for (final root in [
      'base/assets/flutter_assets',
      'assets/flutter_assets',
    ]) {
      final manifest = '$root/NativeAssetsManifest.json';
      test('classifies and hashes the frozen lookup map at $root', () async {
        final bytes = utf8.encode('{"native-assets":{}}');
        expect(differ.isNativeFilePath(manifest), isTrue);
        expect(differ.isAssetFilePath(manifest), isFalse);
        final archive = _androidZip('manifest.zip', [(manifest, bytes)]);
        expect(
          (await differ.fileHashes(archive))[manifest],
          sha256.convert(bytes).toString(),
        );
        final nested = '$root/assets/NativeAssetsManifest.json';
        expect(differ.isNativeFilePath(nested), isFalse);
        expect(differ.isAssetFilePath(nested), isTrue);
      });
      test('rejects duplicate lookup maps at $root', () async {
        final archive = _androidZip('duplicate.zip', [
          (manifest, [1]),
          (manifest, [2]),
        ]);
        await expectLater(differ.fileHashes(archive), throwsFormatException);
      });
      test('validates lookup map local ZIP records at $root', () async {
        final archive = _androidZip('malformed.zip', [
          (manifest, [1]),
        ]);
        final bytes = archive.readAsBytesSync();
        ByteData.sublistView(bytes).setUint32(14, 0, Endian.little);
        archive.writeAsBytesSync(bytes);
        await expectLater(differ.fileHashes(archive), throwsFormatException);
      });
    }

    group('patchable Dart library paths', () {
      for (final prefix in ['base/lib', 'lib', 'jni']) {
        for (final abi in ['armeabi-v7a', 'arm64-v8a', 'x86_64']) {
          final path = '$prefix/$abi/libapp.so';
          test('only delivers canonical $path', () async {
            expect(differ.isDartFilePath(path), isTrue);
            expect(differ.isNativeFilePath(path), isFalse);
            final oldArchive = _androidZip('old.zip', [
              (path, [1]),
            ]);
            final newArchive = _androidZip('new.zip', [
              (path, [2]),
            ]);
            final diff = await differ.changedFiles(
              oldArchive.path,
              newArchive.path,
            );
            expect(differ.dartFileSetDiff(diff).changedPaths, {path});
            expect(
              differ.containsPotentiallyBreakingNativeDiffs(diff),
              isFalse,
            );
          });
        }
      }
      for (final path in [
        'libapp.so',
        'assets/libapp.so',
        'feature/lib/arm64-v8a/libapp.so',
        'base/lib/x86/libapp.so',
        'jni/riscv64/libapp.so',
        'prefix/jni/arm64-v8a/libapp.so',
      ]) {
        test('does not exempt undelivered $path', () {
          expect(differ.isDartFilePath(path), isFalse);
          expect(differ.isNativeFilePath(path), isTrue);
        });
      }
    });

    group('immutable Android code', () {
      test(
        'hashes code bytes while preserving ordinary asset CRC comparison',
        () async {
          final archive = _androidZip('bundle.zip', [
            ('jni/arm64-v8a/libapp.so', [1]),
            ('classes.jar', [2]),
            ('assets/image.png', [3]),
          ]);
          expect(await differ.fileHashes(archive), {
            'jni/arm64-v8a/libapp.so': sha256.convert([1]).toString(),
            'classes.jar': sha256.convert([2]).toString(),
            'assets/image.png': getCrc32([3]).toString(),
          });
        },
      );

      test('same-CRC Dart library updates remain Dart-only changes', () async {
        const path = 'jni/arm64-v8a/libapp.so';
        final oldArchive = _androidZip('old.zip', [(path, _collisionA)]);
        final newArchive = _androidZip('new.zip', [(path, _collisionB)]);
        final diff = await differ.changedFiles(
          oldArchive.path,
          newArchive.path,
        );
        expect(differ.dartFileSetDiff(diff).changedPaths, {path});
        expect(differ.nativeFileSetDiff(diff), isEmpty);
      });

      for (final path in [
        'base/lib/arm64-v8a/libflutter.so',
        'lib/arm64-v8a/libplugin.so',
        'jni/armeabi-v7a/libplugin.so',
        'assets/native/libplugin.so',
        'classes.jar',
        'libs/plugin.jar',
        'com/example/Plugin.class',
      ]) {
        test('detects additions, removals, and changes to $path', () async {
          final oldArchive = _androidZip('old.zip', [
            (path, [1]),
          ]);
          final newArchive = _androidZip('new.zip', [
            (path, [2]),
          ]);
          final empty = _androidZip('empty.zip', []);
          final changed = await differ.changedFiles(
            oldArchive.path,
            newArchive.path,
          );
          expect(differ.nativeFileSetDiff(changed).changedPaths, {path});
          expect(differ.dartFileSetDiff(changed), isEmpty);
          expect(
            differ
                .nativeFileSetDiff(
                  await differ.changedFiles(empty.path, newArchive.path),
                )
                .addedPaths,
            {path},
          );
          expect(
            differ
                .nativeFileSetDiff(
                  await differ.changedFiles(oldArchive.path, empty.path),
                )
                .removedPaths,
            {path},
          );
        });
      }

      for (final path in [
        'base/dex/classes.dex',
        'base/lib/arm64-v8a/libflutter.so',
        'jni/arm64-v8a/plugin.so',
        'classes.jar',
        'com/example/Plugin.class',
      ]) {
        test('same valid ZIP CRC cannot conceal changed $path', () async {
          const oldBytes = _collisionA;
          const newBytes = _collisionB;
          expect(getCrc32(oldBytes), getCrc32(newBytes));
          final oldArchive = _androidZip('old.zip', [(path, oldBytes)]);
          final newArchive = _androidZip('new.zip', [(path, newBytes)]);
          final hashes = await differ.fileHashes(newArchive);
          expect(hashes[path], sha256.convert(newBytes).toString());
          final diff = await differ.changedFiles(
            oldArchive.path,
            newArchive.path,
          );
          expect(differ.nativeFileSetDiff(diff).changedPaths, {path});
        });
      }
    });

    group('native ZIP validation', () {
      for (final directory in ['jni/', 'abc/']) {
        test(
          'rejects linked native ancestor with central name $directory',
          () async {
            final archive = _androidZip('linked.zip', [
              (directory, utf8.encode('/outside')),
              ('jni/arm64-v8a/plugin.so', [1]),
            ]);
            final bytes = archive.readAsBytesSync();
            final data = ByteData.sublistView(bytes);
            // This fixture's EOCD has no comment: its central offset is the
            // uint32 six bytes before EOF. Mark the first record as a symlink.
            final central = data.getUint32(bytes.length - 6, Endian.little);
            data
              ..setUint16(central + 4, (3 << 8) | 20, Endian.little)
              ..setUint32(central + 38, 0xa1ff0000, Endian.little);
            // Extraction uses this local name, even if the central directory
            // presents the innocuous alias abc/ instead of the native ancestor.
            bytes.setRange(30, 34, utf8.encode('jni/'));
            archive.writeAsBytesSync(bytes);
            await expectLater(
              differ.fileHashes(archive),
              throwsFormatException,
            );
          },
        );
      }

      for (final paths in [
        ['jni/arm64-v8a/plugin.so', 'jni/arm64-v8a/plugin.so'],
        ['classes.jar', 'classes.jar'],
        ['base/dex/classes.dex', 'base/dex/classes.dex'],
        ['jni/arm64-v8a/libapp.so', 'jni/arm64-v8a/libapp.so/'],
        ['jni', 'jni/arm64-v8a/plugin.so'],
        ['jni/../plugin.so'],
        [r'jni\arm64-v8a\plugin.so'],
      ]) {
        test('rejects ambiguous code paths $paths', () async {
          final archive = _androidZip('bad.zip', [
            for (final path in paths) (path, [1]),
          ]);
          await expectLater(differ.fileHashes(archive), throwsFormatException);
        });
      }

      final malformed = <String, void Function(ByteData, int)>{
        'symbolic link': (bytes, central) {
          bytes
            ..setUint16(central + 4, (3 << 8) | 20, Endian.little)
            ..setUint32(central + 38, 0xa1ff0000, Endian.little);
        },
        'missing local header': (bytes, central) =>
            bytes.setUint32(0, 0, Endian.little),
        'different local CRC': (bytes, central) =>
            bytes.setUint32(14, 0, Endian.little),
        'different local size': (bytes, central) =>
            bytes.setUint32(22, 99, Endian.little),
        'encrypted payload': (bytes, central) {
          bytes
            ..setUint16(6, 1, Endian.little)
            ..setUint16(central + 8, 1, Endian.little);
        },
        'unsupported compression': (bytes, central) {
          bytes
            ..setUint16(8, 42, Endian.little)
            ..setUint16(central + 10, 42, Endian.little);
        },
        'wrong decompressed length': (bytes, central) {
          bytes
            ..setUint32(22, 99, Endian.little)
            ..setUint32(central + 24, 99, Endian.little);
        },
        'out-of-bounds payload': (bytes, central) {
          bytes
            ..setUint32(18, 99999, Endian.little)
            ..setUint32(central + 20, 99999, Endian.little);
        },
        'invalid compressed payload': (bytes, central) {
          bytes
            ..setUint16(8, 8, Endian.little)
            ..setUint16(central + 10, 8, Endian.little)
            ..setUint8(30 + 'classes.jar'.length, 255);
        },
      };
      for (final invalid in malformed.entries) {
        test('rejects ${invalid.key}', () async {
          final archive = _androidZip('bad.zip', [
            ('classes.jar', [1, 2, 3]),
          ]);
          final bytes = archive.readAsBytesSync();
          invalid.value(
            ByteData.sublistView(bytes),
            30 + 'classes.jar'.length + 3,
          );
          archive.writeAsBytesSync(bytes);
          await expectLater(differ.fileHashes(archive), throwsA(anything));
        });
      }
      test(
        'rejects a native local name disguised as an asset centrally',
        () async {
          final archive = _androidZip('bad.zip', [
            ('payload.xx', [1]),
          ]);
          final bytes = archive.readAsBytesSync()
            ..setRange(30, 40, utf8.encode('payload.so'));
          archive.writeAsBytesSync(bytes);
          await expectLater(differ.fileHashes(archive), throwsFormatException);
        },
      );
    });

    group('aab', () {
      group('changedFiles', () {
        test('finds no differences between the same aab', () async {
          expect(await differ.changedFiles(baseAabPath, baseAabPath), isEmpty);
        });

        test('finds differences between two different aabs', () async {
          final fileSetDiff = await differ.changedFiles(
            baseAabPath,
            changedDartAabPath,
          );
          expect(fileSetDiff.changedPaths, {
            'BUNDLE-METADATA/com.android.tools.build.libraries/dependencies.pb',
            'base/lib/arm64-v8a/libapp.so',
            'base/lib/armeabi-v7a/libapp.so',
            'base/lib/x86_64/libapp.so',
            'META-INF/ANDROIDD.SF',
            'META-INF/ANDROIDD.RSA',
            'META-INF/MANIFEST.MF',
          });
        });

        test('filters out DEX files with only path differences', () async {
          final baseDexAabPath = p.join(
            aabFixturesBasePath,
            'base_dex_test.aab',
          );
          final pathOnlyAabPath = p.join(
            aabFixturesBasePath,
            'changed_dex_path_only.aab',
          );

          final fileSetDiff = await differ.changedFiles(
            baseDexAabPath,
            pathOnlyAabPath,
          );
          // DEX file should be filtered out since only source paths differ.
          expect(
            fileSetDiff.changedPaths.where((p) => p.endsWith('.dex')).isEmpty,
            isTrue,
          );
          expect(
            differ.containsPotentiallyBreakingNativeDiffs(fileSetDiff),
            isFalse,
          );
        });

        test('keeps DEX files with structural changes', () async {
          final baseDexAabPath = p.join(
            aabFixturesBasePath,
            'base_dex_test.aab',
          );
          final methodAddedAabPath = p.join(
            aabFixturesBasePath,
            'changed_dex_method_added.aab',
          );

          final fileSetDiff = await differ.changedFiles(
            baseDexAabPath,
            methodAddedAabPath,
          );
          // DEX file should remain since there are structural changes.
          expect(
            fileSetDiff.changedPaths
                .where((p) => p.endsWith('.dex'))
                .isNotEmpty,
            isTrue,
          );
          expect(
            differ.containsPotentiallyBreakingNativeDiffs(fileSetDiff),
            isTrue,
          );
        });
      });

      group('contentDifferences', () {
        test('detects no differences between the same aab', () async {
          expect(await differ.changedFiles(baseAabPath, baseAabPath), isEmpty);
        });

        test('detects asset changes', () async {
          final fileSetDiff = await differ.changedFiles(
            baseAabPath,
            changedAssetAabPath,
          );
          expect(differ.assetsFileSetDiff(fileSetDiff), isNotEmpty);
          expect(differ.dartFileSetDiff(fileSetDiff), isEmpty);
          expect(differ.nativeFileSetDiff(fileSetDiff), isEmpty);
        });

        test('detects kotlin changes', () async {
          final fileSetDiff = await differ.changedFiles(
            baseAabPath,
            changedKotlinAabPath,
          );
          expect(differ.assetsFileSetDiff(fileSetDiff), isEmpty);
          expect(differ.dartFileSetDiff(fileSetDiff), isEmpty);
          expect(differ.nativeFileSetDiff(fileSetDiff), isNotEmpty);
          expect(
            fileSetDiff.dependencyVersionChanges,
            isEmpty,
          );
        });

        group('dependency versions', () {
          late Directory tempDir;

          setUp(() {
            tempDir = Directory.systemTemp.createTempSync();
          });

          tearDown(() {
            tempDir.deleteSync(recursive: true);
          });

          /// Copies the AAB at [path], replacing its dependency metadata with
          /// [dependencies] (or removing it, if null).
          String withDependencies(String path, Uint8List? dependencies) {
            final source = ZipDecoder().decodeBytes(
              File(path).readAsBytesSync(),
            );
            final copy = Archive();
            for (final file in source.files) {
              if (file.name == bundleDependenciesPath) continue;
              copy.addFile(ArchiveFile(file.name, file.size, file.content));
            }
            if (dependencies != null) {
              copy.addFile(
                ArchiveFile(
                  bundleDependenciesPath,
                  dependencies.length,
                  dependencies,
                ),
              );
            }
            final outPath = p.join(
              tempDir.path,
              '${copy.hashCode}_${p.basename(path)}',
            );
            File(outPath).writeAsBytesSync(ZipEncoder().encode(copy));
            return outPath;
          }

          test('reports version changes when DEX files changed', () async {
            final fileSetDiff = await differ.changedFiles(
              withDependencies(
                baseAabPath,
                appDependencies([
                  mavenLibrary('io.branch.sdk.android', 'library', '5.21.2'),
                  mavenLibrary('com.example', 'same', '1.0.0'),
                ]),
              ),
              withDependencies(
                changedKotlinAabPath,
                appDependencies([
                  mavenLibrary('io.branch.sdk.android', 'library', '5.21.3'),
                  mavenLibrary('com.example', 'same', '1.0.0'),
                ]),
              ),
            );
            expect(
              fileSetDiff.dependencyVersionChanges,
              const [
                DependencyVersionChange(
                  name: 'io.branch.sdk.android:library',
                  oldVersion: '5.21.2',
                  newVersion: '5.21.3',
                ),
              ],
            );
          });

          test('does not compare versions when DEX files match', () async {
            final fileSetDiff = await differ.changedFiles(
              withDependencies(
                baseAabPath,
                appDependencies([mavenLibrary('a', 'b', '1.0.0')]),
              ),
              withDependencies(
                changedDartAabPath,
                appDependencies([mavenLibrary('a', 'b', '2.0.0')]),
              ),
            );
            expect(
              fileSetDiff.dependencyVersionChanges,
              isEmpty,
            );
          });

          test('reports nothing when metadata is missing', () async {
            final fileSetDiff = await differ.changedFiles(
              withDependencies(baseAabPath, null),
              withDependencies(
                changedKotlinAabPath,
                appDependencies([mavenLibrary('a', 'b', '1.0.0')]),
              ),
            );
            expect(differ.nativeFileSetDiff(fileSetDiff), isNotEmpty);
            expect(
              fileSetDiff.dependencyVersionChanges,
              isEmpty,
            );
          });

          test('reports nothing when metadata is malformed', () async {
            final fileSetDiff = await differ.changedFiles(
              withDependencies(baseAabPath, Uint8List.fromList([0x80])),
              withDependencies(
                changedKotlinAabPath,
                appDependencies([mavenLibrary('a', 'b', '1.0.0')]),
              ),
            );
            expect(differ.nativeFileSetDiff(fileSetDiff), isNotEmpty);
            expect(
              fileSetDiff.dependencyVersionChanges,
              isEmpty,
            );
          });
        });

        test('detects dart changes', () async {
          final fileSetDiff = await differ.changedFiles(
            baseAabPath,
            changedDartAabPath,
          );
          expect(differ.assetsFileSetDiff(fileSetDiff), isEmpty);
          expect(differ.dartFileSetDiff(fileSetDiff), isNotEmpty);
          expect(differ.nativeFileSetDiff(fileSetDiff), isEmpty);
        });

        test('detects dart and asset changes', () async {
          final fileSetDiff = await differ.changedFiles(
            baseAabPath,
            changedDartAndAssetAabPath,
          );
          expect(differ.assetsFileSetDiff(fileSetDiff), isNotEmpty);
          expect(differ.dartFileSetDiff(fileSetDiff), isNotEmpty);
          expect(differ.nativeFileSetDiff(fileSetDiff), isEmpty);
        });
      });
    });

    group('aar', () {
      group('changedFiles', () {
        test('finds no differences between the same aar', () async {
          expect(await differ.changedFiles(baseAarPath, baseAarPath), isEmpty);
        });

        test('finds differences between two different aars', () async {
          final fileSetDiff = await differ.changedFiles(
            baseAarPath,
            changedDartAarPath,
          );
          expect(fileSetDiff.changedPaths, {'jni/arm64-v8a/libapp.so'});
        });
      });

      group('changedFiles', () {
        test('detects no differences between the same aar', () async {
          expect(await differ.changedFiles(baseAarPath, baseAarPath), isEmpty);
        });

        test('detects asset changes', () async {
          final fileSetDiff = await differ.changedFiles(
            baseAarPath,
            changedAssetAarPath,
          );
          expect(differ.assetsFileSetDiff(fileSetDiff), isNotEmpty);
          expect(differ.dartFileSetDiff(fileSetDiff), isEmpty);
          expect(differ.nativeFileSetDiff(fileSetDiff), isEmpty);
        });

        test('detects dart changes', () async {
          final fileSetDiff = await differ.changedFiles(
            baseAarPath,
            changedDartAarPath,
          );
          expect(differ.assetsFileSetDiff(fileSetDiff), isEmpty);
          expect(differ.dartFileSetDiff(fileSetDiff), isNotEmpty);
          expect(differ.nativeFileSetDiff(fileSetDiff), isEmpty);
        });

        test('detects dart and asset changes', () async {
          final fileSetDiff = await differ.changedFiles(
            baseAarPath,
            changedDartAndAssetAarPath,
          );
          expect(differ.assetsFileSetDiff(fileSetDiff), isNotEmpty);
          expect(differ.dartFileSetDiff(fileSetDiff), isNotEmpty);
          expect(differ.nativeFileSetDiff(fileSetDiff), isEmpty);
        });
      });

      group('containsPotentiallyBreakingAssetDiffs', () {
        test('returns true if assets were added', () {
          const fileSetDiff = FileSetDiff(
            addedPaths: {'base/assets/flutter_assets/file.json'},
            removedPaths: {},
            changedPaths: {},
          );
          expect(
            differ.containsPotentiallyBreakingAssetDiffs(fileSetDiff),
            isTrue,
          );
        });

        test('returns true if changed assets are not in the ignore list', () {
          const fileSetDiff = FileSetDiff(
            addedPaths: {},
            removedPaths: {},
            changedPaths: {
              'AssetManifest.bin',
              'AssetManifest.json',
              'base/assets/file.json',
            },
          );
          expect(
            differ.containsPotentiallyBreakingAssetDiffs(fileSetDiff),
            isTrue,
          );
        });

        test('returns false if changed assets are in the ignore list', () {
          const fileSetDiff = FileSetDiff(
            addedPaths: {},
            removedPaths: {},
            changedPaths: {
              'base/assets/flutter_assets/AssetManifest.bin',
              'base/assets/flutter_assets/AssetManifest.json',
              'base/assets/flutter_assets/NOTICES.Z',
            },
          );
          expect(
            differ.containsPotentiallyBreakingAssetDiffs(fileSetDiff),
            isFalse,
          );
        });
      });

      group('containsPotentiallyBreakingNativeDiffs', () {
        test('returns true if any native files have been added', () {
          const fileSetDiff = FileSetDiff(
            addedPaths: {'base/lib/arm64-v8a/test.dex'},
            removedPaths: {},
            changedPaths: {},
          );
          expect(
            differ.containsPotentiallyBreakingNativeDiffs(fileSetDiff),
            isTrue,
          );
        });

        test('returns true if any native files have been removed', () {
          const fileSetDiff = FileSetDiff(
            addedPaths: {},
            removedPaths: {'base/lib/arm64-v8a/test.dex'},
            changedPaths: {},
          );
          expect(
            differ.containsPotentiallyBreakingNativeDiffs(fileSetDiff),
            isTrue,
          );
        });

        test('returns true if any native files have been changed', () {
          const fileSetDiff = FileSetDiff(
            addedPaths: {},
            removedPaths: {},
            changedPaths: {'base/lib/arm64-v8a/test.dex'},
          );
          expect(
            differ.containsPotentiallyBreakingNativeDiffs(fileSetDiff),
            isTrue,
          );
        });

        test('returns false if no native files have been changed', () {
          final fileSetDiff = FileSetDiff.empty();
          expect(
            differ.containsPotentiallyBreakingNativeDiffs(fileSetDiff),
            isFalse,
          );
        });
      });
    });
  });
}

// Different payloads with the same actual CRC32, not forged ZIP checksums.
const _collisionA = [
  0xb9,
  0x4d,
  0x73,
  0x78,
  0x93,
  0x28,
  0xff,
  0xe2,
  0x15,
  0xa9,
  0x2c,
  0x5b,
];
const _collisionB = [
  0x29,
  0x35,
  0x01,
  0x6b,
  0x60,
  0xb2,
  0x25,
  0xa9,
  0xd2,
  0xf3,
  0x0f,
  0x34,
];

// Write real stored ZIP records while retaining duplicate central names.
File _androidZip(String path, List<(String, List<int>)> entries) {
  final output = OutputMemoryStream();
  final central = OutputMemoryStream();
  for (final (name, content) in entries) {
    final filename = utf8.encode(name);
    final checksum = getCrc32(content);
    final offset = output.length;
    output
      ..writeUint32(0x04034b50)
      ..writeUint16(20)
      ..writeUint16(0)
      ..writeUint16(0)
      ..writeUint32(0)
      ..writeUint32(checksum)
      ..writeUint32(content.length)
      ..writeUint32(content.length)
      ..writeUint16(filename.length)
      ..writeUint16(0)
      ..writeBytes(filename)
      ..writeBytes(content);
    central
      ..writeUint32(0x02014b50)
      ..writeUint16(20)
      ..writeUint16(20)
      ..writeUint16(0)
      ..writeUint16(0)
      ..writeUint32(0)
      ..writeUint32(checksum)
      ..writeUint32(content.length)
      ..writeUint32(content.length)
      ..writeUint16(filename.length)
      ..writeUint16(0)
      ..writeUint16(0)
      ..writeUint16(0)
      ..writeUint16(0)
      ..writeUint32(0)
      ..writeUint32(offset)
      ..writeBytes(filename);
  }
  final centralOffset = output.length;
  output
    ..writeBytes(central.getBytes())
    ..writeUint32(0x06054b50)
    ..writeUint16(0)
    ..writeUint16(0)
    ..writeUint16(entries.length)
    ..writeUint16(entries.length)
    ..writeUint32(central.length)
    ..writeUint32(centralOffset)
    ..writeUint16(0);
  return File(path)..writeAsBytesSync(output.getBytes());
}
