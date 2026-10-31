import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:shorebird_cli/src/archive/directory_archive.dart';
import 'package:shorebird_cli/src/archive_analysis/archive_analysis.dart';
import 'package:test/test.dart';

import '../helpers.dart';

void main() {
  useTempWorkingDirectory();
  const differ = LinuxBundleDiffer();

  group(LinuxBundleDiffer, () {
    test('identifies assets independently of the host platform', () {
      expect(differ.isAssetFilePath('data/flutter_assets/image.png'), isTrue);
      expect(differ.isAssetFilePath('data/flutter_assets/'), isFalse);
      expect(differ.isAssetFilePath('data/icudtl.dat'), isFalse);
    });

    test('only the exact bundled Dart library is patchable', () {
      expect(differ.isDartFilePath('lib/libapp.so'), isTrue);
      for (final path in [
        'libapp.so',
        'plugins/libapp.so',
        'data/flutter_assets/libapp.so',
        './lib/libapp.so',
        'lib/../lib/libapp.so',
        'lib/libapp.so/',
      ]) {
        expect(differ.isDartFilePath(path), isFalse, reason: path);
      }
    });

    test('recognizes shared library names without hiding plugin libapp.so', () {
      for (final path in [
        'lib/libflutter_linux_gtk.so',
        'lib/plugin.so.1.2.3',
        'libapp.so',
        'lib/native_assets/libapp.so',
        'data/flutter_assets/plugin.so',
      ]) {
        expect(differ.isNativeFilePath(path), isTrue, reason: path);
      }
      for (final path in [
        'lib/libapp.so',
        'lib/plugin.so/',
        'lib/plugin.so.txt/image.png',
        'data/flutter_assets/image.png',
      ]) {
        expect(differ.isNativeFilePath(path), isFalse, reason: path);
      }
    });

    group('fileHashes', () {
      test('uses native SHA-256 and ordinary data CRCs', () async {
        final elf = _elf(0);
        final archive = _writeZip('bundle.zip', [
          _Entry('my_app', elf),
          const _Entry('lib/plugin.so.1', [1]),
          _Entry('data/flutter_assets/opaque.bin', elf),
          const _Entry('data/flutter_assets/helper', [2], mode: 0x81ed),
          _Entry('lib/libapp.so', elf),
          const _Entry('LICENSE', [3]),
          const _Entry('data/flutter_assets/image.png', [4]),
        ], crc: 123);
        expect(await differ.fileHashes(archive), {
          'my_app': _nativeHash(elf),
          'lib/plugin.so.1': _nativeHash([1]),
          'data/flutter_assets/opaque.bin': _nativeHash(elf),
          'data/flutter_assets/helper': _nativeHash([2], executeBits: 0x49),
          'lib/libapp.so': '123',
          'LICENSE': '123',
          'data/flutter_assets/image.png': '123',
        });
      });

      test('non-Unix permission fields remain explicitly unknown', () async {
        final archive = _writeZip('bundle.zip', [
          _Entry('my_app', _elf(0), mode: 0x1ed, creator: 0),
          const _Entry('data/image.png', [1], mode: 0x1ed, creator: 0),
        ], crc: 123);
        expect(await differ.fileHashes(archive), {
          'my_app': _nativeHash(_elf(0), executeBits: null),
          'data/image.png': '123',
        });
      });

      test('accepts case-distinct Linux paths', () async {
        final archive = _writeZip('bundle.zip', const [
          _Entry('lib/plugin.so', [1]),
          _Entry('lib/PLUGIN.so', [2]),
        ]);
        expect((await differ.fileHashes(archive)).keys, {
          'lib/plugin.so',
          'lib/PLUGIN.so',
        });
      });

      for (final path in [
        '../runner',
        '/runner',
        './runner',
        'lib/../lib/libapp.so',
        'lib//plugin.so',
        r'lib\plugin.so',
        'data/\x00file',
      ]) {
        test('rejects ambiguous path $path', () async {
          final archive = _writeZip('bad.zip', [_Entry(path, _elf(0))]);
          await expectLater(differ.fileHashes(archive), throwsFormatException);
        });
      }
      for (final paths in [
        ['my_app', 'my_app'],
        ['lib/libapp.so', 'lib/libapp.so'],
        ['data/image.png', 'data/image.png'],
        ['lib', 'lib/plugin.so'],
        ['lib/', 'lib'],
      ]) {
        test('rejects duplicate or conflicting paths $paths', () async {
          final archive = _writeZip('bad.zip', [
            for (final path in paths) _Entry(path, _elf(0)),
          ]);
          await expectLater(differ.fileHashes(archive), throwsFormatException);
        });
      }
      for (final entry in [
        _Entry('data/image.png', _elf(0), localName: 'my_app'),
        _Entry('lib/libapp.so', _elf(0), localName: 'lib/plugin.so'),
        _Entry('lib/plugin.so', _elf(0), localName: '../plugin.so'),
        const _Entry('lib/plugin.so', [1], mode: 0xa1ff),
        const _Entry('data', [1], mode: 0xa1ff),
      ]) {
        test('rejects inconsistent names or symlinks ${entry.path}', () async {
          final archive = _writeZip('bad.zip', [entry]);
          await expectLater(differ.fileHashes(archive), throwsFormatException);
        });
      }
      final malformed = <String, void Function(ByteData, int)>{
        'missing local record': (bytes, central) =>
            bytes.setUint32(0, 0, Endian.little),
        'different local flags': (bytes, central) =>
            bytes.setUint16(6, 1, Endian.little),
        'encrypted data': (bytes, central) {
          bytes
            ..setUint16(6, 1, Endian.little)
            ..setUint16(central + 8, 1, Endian.little);
        },
        'unsupported compression': (bytes, central) {
          bytes
            ..setUint16(8, 42, Endian.little)
            ..setUint16(central + 10, 42, Endian.little);
        },
        'incorrect uncompressed length': (bytes, central) {
          bytes
            ..setUint32(22, 999, Endian.little)
            ..setUint32(central + 24, 999, Endian.little);
        },
        'out of bounds content': (bytes, central) {
          bytes
            ..setUint32(18, 999, Endian.little)
            ..setUint32(central + 20, 999, Endian.little);
        },
        'invalid compressed data': (bytes, central) {
          bytes
            ..setUint16(8, 8, Endian.little)
            ..setUint16(central + 10, 8, Endian.little)
            ..setUint8(30 + 'my_app'.length, 255);
        },
      };
      for (final testCase in malformed.entries) {
        test('rejects ${testCase.key}', () async {
          final archive = _writeZip('bad.zip', [_Entry('my_app', _elf(0))]);
          final bytes = archive.readAsBytesSync();
          testCase.value(
            ByteData.sublistView(bytes),
            30 + 'my_app'.length + _elf(0).length,
          );
          archive.writeAsBytesSync(bytes);
          await expectLater(differ.fileHashes(archive), throwsA(anything));
        });
      }
    });

    group('changedFiles', () {
      for (final path in [
        'my_app',
        'my.app',
        'lib/plugin.so.1.2',
        'lib/native_assets/libapp.so',
        'data/flutter_assets/native_program.bin',
      ]) {
        test(
          'detects native changes despite identical forged CRCs: $path',
          () async {
            final oldArchive = _writeZip('old.zip', [
              _Entry(path, _elf(0)),
            ], crc: 123);
            final newArchive = _writeZip('new.zip', [
              _Entry(path, _elf(1)),
            ], crc: 123);
            final diff = await differ.changedFiles(
              oldArchive.path,
              newArchive.path,
            );
            expect(diff.changedPaths, {path});
            expect(differ.containsPotentiallyBreakingNativeDiffs(diff), isTrue);
            expect(differ.nativeFileSetDiff(diff).changedPaths, {path});
            expect(
              differ.containsPotentiallyBreakingNativeDiffs(
                diff.where((_) => true),
              ),
              isTrue,
            );
          },
        );
      }
      test('detects added and removed extensionless ELF files', () async {
        final oldArchive = _writeZip('old.zip', [
          _Entry('old_runner', _elf(0)),
        ]);
        final newArchive = _writeZip('new.zip', [
          _Entry('new_runner', _elf(0)),
        ]);
        final diff = await differ.changedFiles(
          oldArchive.path,
          newArchive.path,
        );
        expect(differ.containsPotentiallyBreakingNativeDiffs(diff), isTrue);
        final nativeDiff = differ.nativeFileSetDiff(diff);
        expect(nativeDiff.addedPaths, {'new_runner'});
        expect(nativeDiff.removedPaths, {'old_runner'});
      });
      test(
        'ELF replaced by ordinary data retains old native classification',
        () async {
          final oldArchive = _writeZip('old.zip', [_Entry('my_app', _elf(0))]);
          final newArchive = _writeZip('new.zip', const [
            _Entry('my_app', [1]),
          ]);
          final diff = await differ.changedFiles(
            oldArchive.path,
            newArchive.path,
          );
          expect(differ.containsPotentiallyBreakingNativeDiffs(diff), isTrue);
          expect(differ.nativeFileSetDiff(diff).changedPaths, {'my_app'});
        },
      );
      test('executable scripts under assets are native changes', () async {
        final oldArchive = _writeZip('old.zip', const [
          _Entry('data/flutter_assets/helper', [1], mode: 0x81ed),
        ], crc: 123);
        final newArchive = _writeZip('new.zip', const [
          _Entry('data/flutter_assets/helper', [2], mode: 0x81ed),
        ], crc: 123);
        final diff = await differ.changedFiles(
          oldArchive.path,
          newArchive.path,
        );
        expect(differ.containsPotentiallyBreakingNativeDiffs(diff), isTrue);
        expect(differ.nativeFileSetDiff(diff).changedPaths, {
          'data/flutter_assets/helper',
        });
      });
      test('native execute-bit changes are unpatchable', () async {
        final oldArchive = _writeZip('old.zip', [
          _Entry('my_app', _elf(0), mode: 0x81ed),
        ]);
        final newArchive = _writeZip('new.zip', [_Entry('my_app', _elf(0))]);
        final diff = await differ.changedFiles(
          oldArchive.path,
          newArchive.path,
        );
        expect(differ.containsPotentiallyBreakingNativeDiffs(diff), isTrue);
        expect(differ.nativeFileSetDiff(diff).changedPaths, {'my_app'});
      });
      test(
        'nonexecute Unix permission bits do not change native identity',
        () async {
          final oldArchive = _writeZip('old.zip', [_Entry('my_app', _elf(0))]);
          final newArchive = _writeZip('new.zip', [
            _Entry('my_app', _elf(0), mode: 0x8180),
          ]);
          expect(
            (await differ.changedFiles(
              oldArchive.path,
              newArchive.path,
            )).isEmpty,
            isTrue,
          );
        },
      );

      test('ordinary assets and root data stay nonnative', () async {
        final oldArchive = _writeZip('old.zip', const [
          _Entry('LICENSE', [1]),
          _Entry('data/flutter_assets/image.png', [2]),
        ]);
        final newArchive = _writeZip('new.zip', const [
          _Entry('LICENSE', [3]),
          _Entry('data/flutter_assets/image.png', [4]),
        ]);
        final diff = await differ.changedFiles(
          oldArchive.path,
          newArchive.path,
        );
        expect(differ.containsPotentiallyBreakingNativeDiffs(diff), isFalse);
        expect(differ.containsPotentiallyBreakingAssetDiffs(diff), isTrue);
        expect(differ.nativeFileSetDiff(diff).isEmpty, isTrue);
      });
      test('Dart-only changes are patchable', () async {
        final oldArchive = _writeZip('old.zip', [
          _Entry('my_app', _elf(0)),
          _Entry('lib/libapp.so', _elf(0)),
        ]);
        final newArchive = _writeZip('new.zip', [
          _Entry('my_app', _elf(0)),
          _Entry('lib/libapp.so', _elf(1)),
        ]);
        final diff = await differ.changedFiles(
          oldArchive.path,
          newArchive.path,
        );
        expect(diff.changedPaths, {'lib/libapp.so'});
        expect(differ.containsPotentiallyBreakingNativeDiffs(diff), isFalse);
        expect(differ.dartFileSetDiff(diff).changedPaths, {'lib/libapp.so'});
      });
      test(
        'repackaging and declared CRC differences do not change native bytes',
        () async {
          final oldArchive = _writeZip('old.zip', [
            _Entry('my_app', _elf(0)),
          ], crc: 123);
          final newArchive = _writeZip(
            'new.zip',
            [_Entry('my_app', _elf(0))],
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
    });

    test(
      'accepts production bundle ZIPs with followed library symlinks',
      () async {
        final bundle = Directory('bundle')..createSync();
        Directory('bundle/lib').createSync();
        Directory(
          'bundle/data/flutter_assets/native',
        ).createSync(recursive: true);
        File('bundle/my_app').writeAsBytesSync(_elf(0));
        File('bundle/lib/libapp.so').writeAsBytesSync(_elf(1));
        File('bundle/lib/plugin.so.1').writeAsBytesSync(_elf(0));
        Link('bundle/lib/plugin.so').createSync('plugin.so.1');
        File('bundle/data/flutter_assets/image.png').writeAsBytesSync([1]);
        File(
          'bundle/data/flutter_assets/native/helper',
        ).writeAsStringSync('#!/bin/sh\nexit 0\n');
        expect(
          Process.runSync('chmod', [
            '755',
            File('bundle/data/flutter_assets/native/helper').path,
          ]).exitCode,
          0,
        );
        final archive = await bundle.zipToTempFile();
        addTearDown(() => archive.parent.deleteSync(recursive: true));
        final hashes = await differ.fileHashes(archive);
        expect(hashes['my_app'], _nativeHash(_elf(0)));
        expect(hashes['lib/plugin.so'], _nativeHash(_elf(0)));
        expect(
          hashes['data/flutter_assets/native/helper'],
          _nativeHash(utf8.encode('#!/bin/sh\nexit 0\n'), executeBits: 0x49),
        );
        expect(hashes['lib/libapp.so'], getCrc32(_elf(1)).toString());
        expect(
          hashes['data/flutter_assets/image.png'],
          getCrc32([1]).toString(),
        );
      },
      skip: Platform.isWindows
          ? 'Requires Unix permissions and symlinks'
          : false,
    );
  });
}

// A complete x86-64 ELF executable that exits with the supplied status. It is
// a portable byte fixture; these tests inspect it without running Linux code.
List<int> _elf(int status) => base64.decode(
  'f0VMRgIBAQAAAAAAAAAAAAIAPgABAAAAeABAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAA'
  'AEAAOAABAAAAAAAAAAEAAAAFAAAAAAAAAAAAAAAAAEAAAAAAAAAAQAAAAAAAhAAAAAAA'
  'AACEAAAAAAAAAAAQAAAAAAAAuDwAAAC/AAAAAA8F',
)..[126] = status;

String _nativeHash(List<int> bytes, {int? executeBits = 0}) =>
    '${sha256.convert(bytes)}:unix-exec='
    '${executeBits?.toRadixString(8) ?? 'unknown'}';

class _Entry {
  const _Entry(
    this.path,
    this.bytes, {
    this.mode = 0x81a4,
    this.localName,
    this.creator = 3,
  });

  final String path;
  final List<int> bytes;
  final int mode;
  final String? localName;
  final int creator;
}

// Retain duplicate names and allow declared CRCs that differ from the bytes.
File _writeZip(
  String path,
  List<_Entry> entries, {
  int? crc,
  bool compress = false,
}) {
  final output = OutputMemoryStream();
  final central = OutputMemoryStream();
  for (final entry in entries) {
    final filename = utf8.encode(entry.path);
    final localFilename = utf8.encode(entry.localName ?? entry.path);
    final compressed = compress
        ? ZLibCodec(raw: true).encode(entry.bytes)
        : entry.bytes;
    final checksum = crc ?? getCrc32(entry.bytes);
    final offset = output.length;
    output
      ..writeUint32(0x04034b50)
      ..writeUint16(20)
      ..writeUint16(0)
      ..writeUint16(compress ? 8 : 0)
      ..writeUint32(0)
      ..writeUint32(checksum)
      ..writeUint32(compressed.length)
      ..writeUint32(entry.bytes.length)
      ..writeUint16(localFilename.length)
      ..writeUint16(0)
      ..writeBytes(localFilename)
      ..writeBytes(compressed);
    central
      ..writeUint32(0x02014b50)
      ..writeUint16((entry.creator << 8) | 20)
      ..writeUint16(20)
      ..writeUint16(0)
      ..writeUint16(compress ? 8 : 0)
      ..writeUint32(0)
      ..writeUint32(checksum)
      ..writeUint32(compressed.length)
      ..writeUint32(entry.bytes.length)
      ..writeUint16(filename.length)
      ..writeUint16(0)
      ..writeUint16(0)
      ..writeUint16(0)
      ..writeUint16(0)
      ..writeUint32(entry.mode << 16)
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
