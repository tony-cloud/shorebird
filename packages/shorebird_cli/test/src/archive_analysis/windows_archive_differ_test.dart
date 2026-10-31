import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:shorebird_cli/src/archive_analysis/archive_analysis.dart';
import 'package:test/test.dart';

import '../helpers.dart';

void main() {
  useTempWorkingDirectory();
  const differ = WindowsArchiveDiffer();

  group(WindowsArchiveDiffer, () {
    for (final manifest in [
      'data/flutter_assets/NativeAssetsManifest.json',
      r'data\flutter_assets\NativeAssetsManifest.json',
      'DATA/FLUTTER_ASSETS/NATIVEASSETSMANIFEST.JSON',
      'data/flutter_aſſets/NativeAssetsManifest.json',
      'data/flutter_assets/NativeAſſetsManifeſt.json',
    ]) {
      test('recognizes frozen lookup map $manifest', () async {
        final bytes = utf8.encode('{"native-assets":{}}');
        expect(differ.isNativeFilePath(manifest), isTrue);
        expect(differ.isAssetFilePath(manifest), isFalse);
        final archive = _writeZip('manifest.zip', [
          (manifest, bytes),
        ], crc: 123);
        expect(
          (await differ.fileHashes(archive))[manifest],
          sha256.convert(bytes).toString(),
        );
      });
    }
    test(
      'only the root lookup map is native and aliases cannot duplicate it',
      () async {
        const manifest = 'data/flutter_assets/NativeAssetsManifest.json';
        const nested = 'data/flutter_assets/assets/NativeAssetsManifest.json';
        expect(differ.isNativeFilePath(nested), isFalse);
        expect(differ.isAssetFilePath(nested), isTrue);
        final archive = _writeZip('duplicate.zip', [
          (manifest, [1]),
          (r'DATA\FLUTTER_ASSETS\NATIVEASSETSMANIFEST.JSON', [2]),
        ]);
        await expectLater(differ.fileHashes(archive), throwsFormatException);
        final malformed = _writeZip('malformed.zip', [
          (manifest, [1]),
        ]);
        final bytes = malformed.readAsBytesSync();
        ByteData.sublistView(bytes).setUint32(14, 0, Endian.little);
        malformed.writeAsBytesSync(bytes);
        await expectLater(differ.fileHashes(malformed), throwsFormatException);
      },
    );

    test('classifies assets and Dart independently of host separators', () {
      for (final separator in ['/', r'\']) {
        expect(
          differ.isAssetFilePath(
            'data${separator}flutter_assets${separator}image.png',
          ),
          isTrue,
        );
        expect(
          differ.isAssetFilePath('data${separator}flutter_assets$separator'),
          isFalse,
        );
        expect(differ.isDartFilePath('data${separator}app.so'), isTrue);
      }
      expect(differ.isAssetFilePath('foo/bar'), isFalse);
      expect(differ.isDartFilePath('foo.so'), isFalse);
    });

    group('isNativeFilePath', () {
      for (final path in [
        'runner.exe',
        'flutter_windows.dll',
        r'C:\path\to\RUNNER.EXE',
        r'data\flutter_assets\plugin.DlL',
        'data/flutter_assets/plugin.dll',
      ]) {
        test('recognizes $path', () {
          expect(differ.isNativeFilePath(path), isTrue);
        });
      }
      for (final path in [
        'data/app.so',
        'runner.pdb',
        'runner.exe/',
        r'plugin.DLL\',
        'runner.exe.txt',
      ]) {
        test('excludes $path', () {
          expect(differ.isNativeFilePath(path), isFalse);
        });
      }
    });

    group('archive namespace', () {
      Future<void> expectRejected(File archive) async {
        await expectLater(
          differ.validateArchive(archive),
          throwsFormatException,
        );
        await expectLater(differ.fileHashes(archive), throwsFormatException);
      }

      for (final path in [
        '',
        '/',
        '/data/image.png',
        r'\data\image.png',
        r'\\server\share\image.png',
        'C:/data/image.png',
        r'C:\data\image.png',
        'C:image.png',
        '../image.png',
        'data/../image.png',
        r'data\..\image.png',
        'data/./image.png',
        'data//image.png',
        'data/image.png/',
        'data/image.png.',
        'data/image.png ',
        'data./image.png',
        'data /image.png',
        'data/image.png:stream',
        'data/image.png\x00',
        'data/line\nbreak.png',
        'data/im<age.png',
        'data/im>age.png',
        'data/im"age.png',
        'data/im|age.png',
        'data/im?age.png',
        'data/im*age.png',
        'CON',
        'data/nUl.txt',
        'data/NUL .txt',
        'data/NUL .txt/image.png',
        'data/PRN/image.png',
        'AUX.json',
        'COM1.txt',
        'COM1 .txt',
        'lpt9',
        'COM¹.txt',
        'LPT²/image.png',
        r'CONIN$',
        r'conout$.txt',
        r'CLOCK$',
      ]) {
        test('rejects unsafe nonnative Windows path ${jsonEncode(path)}', () {
          return expectRejected(
            _writeZip('unsafe.zip', [
              (path, [1]),
            ]),
          );
        });
      }

      for (final aliases in [
        ('data/app.so', 'DATA/APP.SO'),
        ('data/σ.png', 'DATA/ς.PNG'),
        ('data/flutter_assets/image.png', r'DATA\FLUTTER_ASSETS\IMAGE.PNG'),
        ('data/', 'DATA/'),
        ('data/', r'data\'),
        ('data', 'DATA/'),
      ]) {
        test('rejects duplicate nonnative identities $aliases', () async {
          await expectRejected(
            _writeZip('duplicate.zip', [
              (aliases.$1, []),
              (aliases.$2, []),
            ]),
          );
        });
      }

      for (final parentFirst in [true, false]) {
        test(
          'rejects file ancestors regardless of entry order $parentFirst',
          () {
            final entries = [
              ('plugins', [1]),
              (r'PLUGINS\nested\plugin.dll', [2]),
            ];
            return expectRejected(
              _writeZip(
                'ancestor.zip',
                parentFirst ? entries : entries.reversed.toList(),
              ),
            );
          },
        );
      }

      test('rejects Unicode case aliases for file ancestors', () {
        return expectRejected(
          _writeZip('ancestor.zip', [
            ('σ', [1]),
            ('ς/plugin.dll', [2]),
          ]),
        );
      });

      test('rejects nonnative local and central filename disagreement', () {
        final archive = _writeZip('alias.zip', [
          ('data/one.png', [1]),
        ]);
        final bytes = archive.readAsBytesSync()
          ..setRange(30, 42, utf8.encode('data/two.png'));
        archive.writeAsBytesSync(bytes);
        return expectRejected(archive);
      });

      for (final attributes in [
        0xa1ff0000, // Symbolic link.
        0x11ff0000, // FIFO.
        0x21ff0000, // Character device.
        0x61ff0000, // Block device.
        0xc1ff0000, // Socket.
        0x41ff0000, // Directory without a trailing separator.
        0x10, // DOS directory without a trailing separator.
        0x08, // DOS volume label.
        0x40, // Windows device.
        0x400, // Windows reparse point.
      ]) {
        test('rejects nonnative special type $attributes', () {
          final archive = _writeZip('special.zip', [
            ('data/image.png', [1]),
          ], attributes: attributes);
          return expectRejected(archive);
        });
      }

      test('rejects a regular file marked with a directory separator', () {
        return expectRejected(
          _writeZip('directory.zip', [
            ('data/', []),
          ], attributes: 0x81a40000),
        );
      });

      test(
        'supports directory records, implicit parents and Windows names',
        () async {
          final archive = _writeZip('safe.zip', [
            ('plugins/', []),
            (r'plugins\Nested\', []),
            (r'plugins\Nested\Plugin.DLL', [1]),
            ('data/app.so', [2]),
            ('data/flutter_assets/Com10 café.png', [3]),
            ('data/flutter_assets/.metadata', [4]),
            ('data/flutter_assets/image .png', [5]),
          ]);
          await expectLater(differ.validateArchive(archive), completes);
          expect(await differ.fileHashes(archive), {
            'plugins/': '0',
            r'plugins\Nested\': '0',
            r'plugins\Nested\Plugin.DLL': sha256.convert([1]).toString(),
            'data/app.so': getCrc32([2]).toString(),
            'data/flutter_assets/Com10 café.png': getCrc32([3]).toString(),
            'data/flutter_assets/.metadata': getCrc32([4]).toString(),
            'data/flutter_assets/image .png': getCrc32([5]).toString(),
          });
        },
      );

      for (final attributes in [0x10, 0x41ed0010]) {
        test('supports ordinary directory attributes $attributes', () async {
          final archive = _writeZip('directory.zip', [
            ('data/', []),
          ], attributes: attributes);
          await expectLater(differ.validateArchive(archive), completes);
          expect(await differ.fileHashes(archive), {'data/': '0'});
        });
      }

      test('supports ordinary encoded ZIPs', () async {
        final archive = Archive()
          ..add(ArchiveFile.directory('data/'))
          ..add(ArchiveFile('runner.exe', 3, [1, 2, 3]))
          ..add(ArchiveFile('data/app.so', 1, [4]));
        final file = File('encoded.zip')
          ..writeAsBytesSync(ZipEncoder().encode(archive));
        await expectLater(differ.validateArchive(file), completes);
        expect(await differ.fileHashes(file), {
          'data/': '0',
          'runner.exe': sha256.convert([1, 2, 3]).toString(),
          'data/app.so': getCrc32([4]).toString(),
        });
      });
    });

    group('fileHashes', () {
      test(
        'hashes actual native content and preserves nonnative CRCs',
        () async {
          final archive = _writeZip('app.zip', [
            ('runner.exe', [1, 2, 3]),
            ('data/app.so', [4, 5]),
            ('data/flutter_assets/image.png', [6]),
          ], crc: 123);
          expect(await differ.fileHashes(archive), {
            'runner.exe': sha256.convert([1, 2, 3]).toString(),
            'data/app.so': '123',
            'data/flutter_assets/image.png': '123',
          });
        },
      );

      test('Linux nonnative files retain declared CRC behavior', () async {
        final oldArchive = _writeZip('old.zip', [
          ('runner.exe', [1]),
        ], crc: 123);
        final newArchive = _writeZip('new.zip', [
          ('runner.exe', [2]),
        ], crc: 123);
        const linuxDiffer = LinuxBundleDiffer();
        expect(await linuxDiffer.fileHashes(oldArchive), {'runner.exe': '123'});
        expect(
          (await linuxDiffer.changedFiles(
            oldArchive.path,
            newArchive.path,
          )).isEmpty,
          isTrue,
        );
      });

      for (final aliases in [
        ('runner.exe', 'runner.exe'),
        ('runner.exe', 'RUNNER.EXE'),
        ('plugins/plugin.dll', r'plugins\plugin.dll'),
        ('plugins/plugin.dll', 'plugins/./plugin.dll'),
      ]) {
        test('rejects duplicate native identities $aliases', () async {
          final archive = _writeZip('duplicate.zip', [
            (aliases.$1, [1]),
            (aliases.$2, [2]),
          ]);
          await expectLater(differ.fileHashes(archive), throwsFormatException);
        });
      }

      test(
        'rejects a native local name hidden by a nonnative central name',
        () async {
          final archive = _writeZip('alias.zip', [
            ('runner.txt', [1]),
          ]);
          final bytes = archive.readAsBytesSync()
            ..setRange(30, 40, utf8.encode('runner.exe'));
          archive.writeAsBytesSync(bytes);
          await expectLater(differ.fileHashes(archive), throwsFormatException);
        },
      );

      test('supports native local ZIP64 sizes', () async {
        final archive = _writeZip(
          'zip64.zip',
          [
            ('runner.exe', [1, 2, 3]),
          ],
          zip64Local: true,
        );
        expect(await differ.fileHashes(archive), {
          'runner.exe': sha256.convert([1, 2, 3]).toString(),
        });
      });

      test('supports native entries with data descriptors', () async {
        final archive = _writeZip(
          'descriptor.zip',
          [
            ('runner.exe', [1, 2, 3]),
          ],
          descriptor: true,
          compress: true,
        );
        expect(await differ.fileHashes(archive), {
          'runner.exe': sha256.convert([1, 2, 3]).toString(),
        });
      });
      test('rejects inconsistent native data descriptors', () async {
        final archive = _writeZip(
          'descriptor.zip',
          [
            ('runner.exe', [1, 2, 3]),
          ],
          descriptor: true,
        );
        final bytes = archive.readAsBytesSync();
        ByteData.sublistView(bytes).setUint32(
          30 + 'runner.exe'.length + 3 + 8,
          4,
          Endian.little,
        );
        archive.writeAsBytesSync(bytes);
        await expectLater(differ.fileHashes(archive), throwsFormatException);
      });

      final malformed = <String, void Function(ByteData, int)>{
        'native symbolic link': (bytes, central) {
          bytes
            ..setUint16(central + 4, (3 << 8) | 20, Endian.little)
            ..setUint32(central + 38, 0xa1ff0000, Endian.little);
        },
        'missing local record': (bytes, central) =>
            bytes.setUint32(0, 0, Endian.little),
        'different local name': (bytes, central) => bytes.setUint8(30, 120),
        'different local CRC': (bytes, central) =>
            bytes.setUint32(14, 0, Endian.little),
        'different local flags': (bytes, central) =>
            bytes.setUint16(6, 1, Endian.little),
        'encrypted entry': (bytes, central) {
          bytes
            ..setUint16(6, 1, Endian.little)
            ..setUint16(central + 8, 1, Endian.little);
        },
        'unsupported compression': (bytes, central) {
          bytes
            ..setUint16(8, 42, Endian.little)
            ..setUint16(central + 10, 42, Endian.little);
        },
        'inconsistent local size': (bytes, central) =>
            bytes.setUint32(22, 42, Endian.little),
        'incorrect uncompressed length': (bytes, central) {
          bytes
            ..setUint32(22, 42, Endian.little)
            ..setUint32(central + 24, 42, Endian.little);
        },
        'out of bounds payload': (bytes, central) {
          bytes
            ..setUint32(18, 999, Endian.little)
            ..setUint32(central + 20, 999, Endian.little);
        },
        'invalid deflate payload': (bytes, central) {
          bytes
            ..setUint16(8, 8, Endian.little)
            ..setUint16(central + 10, 8, Endian.little)
            ..setUint8(30 + 'runner.exe'.length, 255);
        },
      };
      for (final testCase in malformed.entries) {
        test('rejects ${testCase.key}', () async {
          final archive = _writeZip('bad.zip', [
            ('runner.exe', [1, 2, 3]),
          ]);
          final bytes = archive.readAsBytesSync();
          final data = ByteData.sublistView(bytes);
          const central = 30 + 'runner.exe'.length + 3;
          testCase.value(data, central);
          archive.writeAsBytesSync(bytes);
          await expectLater(differ.fileHashes(archive), throwsA(anything));
        });
      }
      test('rejects a missing ZIP directory', () async {
        final archive = File('bad.zip')..writeAsStringSync('not a zip');
        await expectLater(differ.fileHashes(archive), throwsFormatException);
      });
    });

    group('changedFiles', () {
      for (final name in [
        'runner.exe',
        'plugins/plugin.DLL',
        'data/flutter_assets/plugin.dll',
      ]) {
        test(
          'detects additions, removals, and changed bytes for $name',
          () async {
            final oldArchive = _writeZip('old.zip', [
              (name, [1]),
            ]);
            final newArchive = _writeZip('new.zip', [
              (name, [2]),
              ('added.dll', [3]),
            ]);
            final diff = await differ.changedFiles(
              oldArchive.path,
              newArchive.path,
            );
            expect(diff.changedPaths, {name});
            expect(diff.addedPaths, {'added.dll'});
            expect(differ.containsPotentiallyBreakingNativeDiffs(diff), isTrue);
            final reverse = await differ.changedFiles(
              newArchive.path,
              oldArchive.path,
            );
            expect(reverse.removedPaths, {'added.dll'});
          },
        );
      }
      test(
        'identical native bytes survive repackaging and CRC changes',
        () async {
          final oldArchive = _writeZip('old.zip', [
            ('runner.exe', [1, 2, 3]),
          ], crc: 123);
          final newArchive = _writeZip(
            'new.zip',
            [
              ('runner.exe', [1, 2, 3]),
            ],
            crc: 456,
            compress: true,
          );
          expect(
            (await differ.changedFiles(
              oldArchive.path,
              newArchive.path,
            )).isEmpty,
            isTrue,
          );
        },
      );
      test('equal forged CRCs cannot hide different native bytes', () async {
        final oldArchive = _writeZip('old.zip', [
          ('runner.exe', [1, 2, 3]),
        ], crc: 123);
        final newArchive = _writeZip('new.zip', [
          ('runner.exe', [4, 5, 6]),
        ], crc: 123);
        expect(
          (await differ.changedFiles(
            oldArchive.path,
            newArchive.path,
          )).changedPaths,
          {'runner.exe'},
        );
      });
    });
  });
}

// Write ZIP records directly so duplicate names and forged CRCs are retained.
File _writeZip(
  String path,
  List<(String, List<int>)> entries, {
  int? crc,
  bool compress = false,
  bool descriptor = false,
  bool zip64Local = false,
  int attributes = 0,
}) {
  final output = OutputMemoryStream();
  final central = OutputMemoryStream();
  for (final (name, content) in entries) {
    final filename = utf8.encode(name);
    final compressed = compress
        ? ZLibCodec(raw: true).encode(content)
        : content;
    final checksum = crc ?? getCrc32(content);
    final offset = output.length;
    output
      ..writeUint32(0x04034b50)
      ..writeUint16(20)
      ..writeUint16(descriptor ? 8 : 0)
      ..writeUint16(compress ? 8 : 0)
      ..writeUint32(0)
      ..writeUint32(descriptor ? 0 : checksum)
      ..writeUint32(
        zip64Local ? 0xffffffff : (descriptor ? 0 : compressed.length),
      )
      ..writeUint32(zip64Local ? 0xffffffff : (descriptor ? 0 : content.length))
      ..writeUint16(filename.length)
      ..writeUint16(zip64Local ? 20 : 0)
      ..writeBytes(filename);
    if (zip64Local) {
      output
        ..writeUint16(1)
        ..writeUint16(16)
        ..writeUint64(content.length)
        ..writeUint64(compressed.length);
    }
    output.writeBytes(compressed);
    if (descriptor) {
      output
        ..writeUint32(0x08074b50)
        ..writeUint32(checksum)
        ..writeUint32(compressed.length)
        ..writeUint32(content.length);
    }
    central
      ..writeUint32(0x02014b50)
      ..writeUint16(20)
      ..writeUint16(20)
      ..writeUint16(descriptor ? 8 : 0)
      ..writeUint16(compress ? 8 : 0)
      ..writeUint32(0)
      ..writeUint32(checksum)
      ..writeUint32(compressed.length)
      ..writeUint32(content.length)
      ..writeUint16(filename.length)
      ..writeUint16(0)
      ..writeUint16(0)
      ..writeUint16(0)
      ..writeUint16(0)
      ..writeUint32(attributes)
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
