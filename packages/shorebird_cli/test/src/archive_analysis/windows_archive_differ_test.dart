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

      test('Linux retains the inherited declared CRC behavior', () async {
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
