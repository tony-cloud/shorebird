import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/archive_analysis/apple_archive_differ.dart';
import 'package:test/test.dart';

import '../platform/apple/macho_fixture.dart'
    show image, signedImage, universal;

void main() {
  late Directory temp;
  const differ = AppleArchiveDiffer();
  setUp(() => temp = Directory.systemTemp.createTempSync('apple_security.'));
  tearDown(() => temp.deleteSync(recursive: true));

  File zip(
    String name,
    Map<String, List<int>> entries, {
    Map<String, String> links = const {},
  }) {
    final archive = Archive();
    for (final entry in entries.entries) {
      archive.add(ArchiveFile(entry.key, entry.value.length, entry.value));
    }
    for (final link in links.entries) {
      final target = utf8.encode(link.value);
      archive.add(ArchiveFile(link.key, target.length, target)..mode = 0xa1ff);
    }
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
    final data = ByteData.sublistView(bytes);
    // package:archive's encoder writes DOS creator IDs even for UNIX modes.
    var offset = data.getUint32(bytes.length - 6, Endian.little);
    while (data.getUint32(offset, Endian.little) == 0x02014b50) {
      data.setUint16(offset + 4, 0x0314, Endian.little);
      offset +=
          46 +
          data.getUint16(offset + 28, Endian.little) +
          data.getUint16(offset + 30, Endian.little) +
          data.getUint16(offset + 32, Endian.little);
    }
    for (final entry in entries.keys.where((key) => key.contains(r'\'))) {
      final normalized = utf8.encode(entry.replaceAll(r'\', '/'));
      final original = utf8.encode(entry);
      for (var i = 0; i <= bytes.length - normalized.length; i++) {
        if (List.generate(
          normalized.length,
          (j) => bytes[i + j] == normalized[j],
        ).every((equal) => equal)) {
          bytes.setRange(i, i + original.length, original);
        }
      }
    }
    return File(p.join(temp.path, '$name.zip'))..writeAsBytesSync(bytes);
  }

  for (final path in [
    'Products/Applications/Runner.app/Runner',
    'Payload/Runner.app/Frameworks/Plugin.framework/Plugin',
    'Payload/Runner.app/Frameworks/Flutter.framework/Flutter',
    'Contents/Frameworks/FlutterMacOS.framework/Versions/A/FlutterMacOS',
    'Contents/Frameworks/Plugin.framework/Versions/A/Plugin',
    'Contents/Frameworks/custom.dylib',
    'Payload/Runner.app/Helpers/suffixless',
  ]) {
    test('detects changed, added and removed native bytes in $path', () async {
      final a = zip('a', {path: image()});
      final bytes = image()..last = 7;
      final b = zip('b', {path: bytes});
      final empty = zip('empty', {
        'readme': [1],
      });
      for (final pair in [(a, b), (a, empty), (empty, b)]) {
        final changes = await differ.changedFiles(pair.$1.path, pair.$2.path);
        expect(differ.containsPotentiallyBreakingNativeDiffs(changes), isTrue);
        expect(differ.nativeFileSetDiff(changes).prettyString, contains(path));
      }
    });
  }
  test(
    'detects changed universal executable and ignores only UUID changes',
    () async {
      const path = 'Payload/Runner.app/Helpers/universal';
      final a = zip('a', {path: universal(image())});
      final b = zip('b', {path: universal(image(uuid: 2))});
      expect(await differ.changedFiles(a.path, b.path), isEmpty);
      final edited = universal(image())..last = 7;
      final c = zip('c', {path: edited});
      expect(
        differ.containsPotentiallyBreakingNativeDiffs(
          await differ.changedFiles(a.path, c.path),
        ),
        isTrue,
      );
    },
  );
  for (final path in [
    'Payload/Runner.app/Frameworks/App.framework/App',
    'Contents/Frameworks/App.framework/Versions/A/App',
    'ios-arm64/App.framework/App',
  ]) {
    test('preserves generated Dart exemption at $path', () async {
      final a = zip('a', {path: image()});
      final b = zip('b', {path: image()..last = 7});
      final changes = await differ.changedFiles(a.path, b.path);
      expect(differ.dartFileSetDiff(changes), isNotEmpty);
      expect(differ.nativeFileSetDiff(changes), isEmpty);
    });
  }
  for (final path in [
    'Payload/Runner.app/Frameworks/NotApp.framework/App',
    'Payload/Runner.app/Frameworks/Plugin.framework/Resources/App.framework/App',
    'arbitrary/App.framework/App',
  ]) {
    test('does not exempt native lookalike at $path', () async {
      final a = zip('a', {path: image()});
      final b = zip('b', {path: image()..last = 7});
      final changes = await differ.changedFiles(a.path, b.path);
      expect(differ.nativeFileSetDiff(changes), isNotEmpty);
    });
  }
  test('retains non-Mach-O native pathname changes as actual bytes', () async {
    const path = 'Contents/Frameworks/Plugin.framework/Plugin';
    final a = zip('a', {
      path: [1],
    });
    final b = zip('b', {
      path: [2],
    });
    expect(
      differ.containsPotentiallyBreakingNativeDiffs(
        await differ.changedFiles(a.path, b.path),
      ),
      isTrue,
    );
  });
  test('accepts framework symlinks and detects alias target changes', () async {
    const root = 'Contents/Frameworks/Plugin.framework';
    final entries = {
      '$root/Versions/A/Plugin': image(),
      '$root/Versions/B/Plugin': image(),
    };
    final a = zip(
      'a',
      entries,
      links: {
        '$root/Plugin': 'Versions/Current/Plugin',
        '$root/Versions/Current': 'A',
      },
    );
    final b = zip(
      'b',
      entries,
      links: {
        '$root/Plugin': 'Versions/Current/Plugin',
        '$root/Versions/Current': 'B',
      },
    );
    expect(await differ.changedFiles(a.path, a.path), isEmpty);
    final changes = await differ.changedFiles(a.path, b.path);
    expect(differ.nativeFileSetDiff(changes).changedPaths, {
      '$root/Versions/Current',
    });
  });
  for (final target in [
    '/tmp/escape',
    '../../../../escape',
    'Current',
    'Missing',
  ]) {
    test('rejects unsafe framework link $target', () async {
      final a = zip(
        'a',
        {'Plugin.framework/Versions/A/Plugin': image()},
        links: {'Plugin.framework/Versions/Current': target},
      );
      await expectLater(
        differ.changedFiles(a.path, a.path),
        throwsFormatException,
      );
    });
  }
  test(
    'rejects archive paths without writing outside scratch directories',
    () async {
      final sentinel = File(p.join(temp.path, 'sentinel'))
        ..writeAsStringSync('owned sentinel');
      for (final name in [
        '../sentinel',
        sentinel.path,
        '../App.framework/App',
        '../Assets.car',
        'C:/App.framework/App',
        'nested/../App.framework/App',
        'nested//Assets.car',
        r'nested\App.framework\App',
      ]) {
        final a = zip('attack', {name: image()});
        await IOOverrides.runZoned(
          () => expectLater(
            differ.changedFiles(a.path, a.path),
            throwsFormatException,
            reason: name,
          ),
          getSystemTempDirectory: () => temp,
        );
        expect(sentinel.readAsStringSync(), 'owned sentinel');
      }
      expect(temp.listSync().whereType<Directory>(), isEmpty);
    },
  );
  test(
    'detects native payload changes with colliding CRC32 checksums',
    () async {
      List<int> decode(String hex) => [
        for (var i = 0; i < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ];
      final first = decode('624e35f6360fb202ba6b30190c8f57e6');
      final second = decode('dcd6b4f7cc0547dace0e5be53ebaa2a8');
      expect(getCrc32(first), getCrc32(second));
      const path = 'Contents/Frameworks/Plugin.framework/Plugin';
      final a = zip('a', {path: first});
      final b = zip('b', {path: second});
      expect(
        differ.nativeFileSetDiff(await differ.changedFiles(a.path, b.path)),
        isNotEmpty,
      );
    },
  );
  test('a fat image with one runtime slice remains native', () async {
    final debug = image();
    ByteData.sublistView(debug).setUint32(12, 0xa, Endian.little);
    const path = 'Contents/Resources/extra';
    final a = zip('a', {path: universal(debug, secondSlice: image())});
    final b = zip('b', {
      path: universal(debug, secondSlice: image()..last = 7),
    });
    expect(
      differ.nativeFileSetDiff(await differ.changedFiles(a.path, b.path)),
      isNotEmpty,
    );
  });
  test(
    'rejects invalid signed images without leaving scratch copies',
    () async {
      final bytes = image();
      ByteData.sublistView(bytes)
        ..setUint32(20, 16, Endian.little)
        ..setUint32(32, 0x1d, Endian.little)
        ..setUint32(36, 16, Endian.little)
        ..setUint32(40, 48, Endian.little)
        ..setUint32(44, 16, Endian.little);
      final a = zip('a', {'Contents/MacOS/native': bytes});
      await IOOverrides.runZoned(
        () => expectLater(
          differ.changedFiles(a.path, a.path),
          throwsFormatException,
        ),
        getSystemTempDirectory: () => temp,
      );
      expect(temp.listSync().whereType<Directory>(), isEmpty);
    },
  );
  test(
    'accepts production ditto archives with versioned framework symlinks',
    () async {
      final app = Directory(p.join(temp.path, 'Runner.app'));
      final framework = p.join(
        app.path,
        'Contents',
        'Frameworks',
        'Plugin.framework',
      );
      final version = Directory(p.join(framework, 'Versions', 'A'))
        ..createSync(recursive: true);
      File(p.join(version.path, 'Plugin')).writeAsBytesSync(image());
      Link(p.join(framework, 'Versions', 'Current')).createSync('A');
      Link(p.join(framework, 'Plugin')).createSync('Versions/Current/Plugin');
      final output = p.join(temp.path, 'ditto.zip');
      final result = Process.runSync('ditto', ['-c', '-k', app.path, output]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(await differ.changedFiles(output, output), isEmpty);
    },
    testOn: 'mac-os',
  );
  test('resolves symlinks before following parent components', () async {
    final a = zip(
      'a',
      {
        'Plugin.framework/a/outside': [1],
      },
      links: {
        'Plugin.framework/a/b/c': '..',
        'Plugin.framework/L': 'a/b/c/../../outside',
      },
    );
    await expectLater(
      differ.changedFiles(a.path, a.path),
      throwsFormatException,
    );
  });
  test('rejects descendants through a trailing-slash symlink', () async {
    final a = zip(
      'a',
      {
        'Plugin.framework/Versions/A/Plugin': image(),
        'Plugin.framework/alias/child': [1],
      },
      links: {'Plugin.framework/alias/': 'Versions/A'},
    );
    await expectLater(
      differ.changedFiles(a.path, a.path),
      throwsFormatException,
    );
  });
  for (final target in [
    'Versions/A/Plugin/../Plugin',
    'Missing/../Versions/A/Plugin',
  ]) {
    test('rejects a non-traversable symlink target $target', () async {
      final a = zip(
        'a',
        {'Plugin.framework/Versions/A/Plugin': image()},
        links: {'Plugin.framework/Plugin': target},
      );
      await expectLater(
        differ.changedFiles(a.path, a.path),
        throwsFormatException,
      );
    });
  }
  test('detects replacing symlinks with same-byte regular files', () async {
    const binary = 'Plugin.framework/Versions/A/Plugin';
    const alias = 'Plugin.framework/Plugin';
    final a = zip('a', {binary: image()}, links: {alias: 'Versions/A/Plugin'});
    final b = zip('b', {
      binary: image(),
      alias: utf8.encode('Versions/A/Plugin'),
    });
    for (final pair in [(a, b), (b, a)]) {
      final changes = await differ.changedFiles(pair.$1.path, pair.$2.path);
      expect(differ.nativeFileSetDiff(changes).changedPaths, {alias});
    }
  });
  test('accepts valid JVM class assets sharing the universal magic', () async {
    // Java 8 class C extends java/lang/Object, with no fields or methods.
    final java = <int>[
      0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 52, 0, 5,
      1, 0, 1, 67, // CONSTANT_Utf8: C.
      7, 0, 1, // CONSTANT_Class: C.
      1, 0, 16, ...ascii.encode('java/lang/Object'),
      7, 0, 3, // CONSTANT_Class: java/lang/Object.
      0, 0x21, 0, 2, 0, 4, // public/super, this, super.
      0, 0, 0, 0, 0, 0, 0, 0, // interfaces, fields, methods, attributes.
    ];
    const path = 'Contents/Resources/flutter_assets/C.class';
    final a = zip('a', {path: java});
    final updated = List<int>.from(java)..[13] = 68; // Class name D.
    final b = zip('b', {path: updated});
    final changes = await differ.changedFiles(a.path, b.path);
    expect(differ.assetsFileSetDiff(changes).changedPaths, {path});
    expect(differ.nativeFileSetDiff(changes), isEmpty);
    for (final nativePath in [
      'Contents/MacOS/Runner',
      'Contents/Frameworks/App.framework/App',
    ]) {
      final native = zip('native', {nativePath: java});
      await expectLater(
        differ.changedFiles(native.path, native.path),
        throwsFormatException,
      );
    }
  });
  test(
    'valid universal images remain native regardless class suffix',
    () async {
      const path = 'Contents/Resources/library.class';
      final a = zip('a', {path: universal(image())});
      final b = zip('b', {path: universal(image()..last = 7)});
      expect(
        differ.nativeFileSetDiff(await differ.changedFiles(a.path, b.path)),
        isNotEmpty,
      );
      final invalid = zip('invalid', {
        path: [0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 52],
      });
      expect(
        differ.nativeFileSetDiff(
          await differ.changedFiles(a.path, invalid.path),
        ),
        isNotEmpty,
      );
    },
  );
  test(
    'bad signed universal boundaries cannot fall back to class resources',
    () async {
      final bytes = signedImage();
      ByteData.sublistView(bytes).setUint32(32 + 72 + 56, 5, Endian.little);
      final a = zip('a', {'Contents/Resources/signed.class': universal(bytes)});
      await expectLater(
        differ.changedFiles(a.path, a.path),
        throwsFormatException,
      );
    },
  );
  test('rejects duplicate ZIP names and inconsistent local records', () async {
    final a = zip('a', {
      'one': [1],
      'two': [2],
    });
    final original = a.readAsBytesSync();
    for (final centralOnly in [false, true]) {
      final bytes = Uint8List.fromList(original);
      var seen = 0;
      for (var i = 0; i <= bytes.length - 3; i++) {
        if (ascii.decode(bytes.sublist(i, i + 3), allowInvalid: true) ==
            'two') {
          seen++;
          if (!centralOnly || seen == 2) {
            bytes.setRange(i, i + 3, ascii.encode('one'));
          }
        }
      }
      a.writeAsBytesSync(bytes);
      await expectLater(
        differ.changedFiles(a.path, a.path),
        throwsFormatException,
      );
    }
  });
  test(
    'rejects recognized malformed Mach-O instead of treating it as data',
    () async {
      final a = zip('a', {'helper': image().sublist(0, 4)});
      await expectLater(
        differ.changedFiles(a.path, a.path),
        throwsFormatException,
      );
    },
  );

  test(
    'normalizes real codesign signatures while retaining executable code',
    () async {
      final source = File(p.join(temp.path, 'main.c'))
        ..writeAsStringSync('int main(void) { return 0; }');
      final binary = File(p.join(temp.path, 'native'));
      final compile = Process.runSync('xcrun', [
        'clang',
        source.path,
        '-o',
        binary.path,
      ]);
      expect(compile.exitCode, 0, reason: '${compile.stderr}');
      final unsigned = Process.runSync('codesign', [
        '--remove-signature',
        binary.path,
      ]);
      expect(unsigned.exitCode, 0, reason: '${unsigned.stderr}');
      final firstSign = Process.runSync('codesign', [
        '--force',
        '--sign',
        '-',
        '--identifier',
        'first.native',
        binary.path,
      ]);
      expect(firstSign.exitCode, 0, reason: '${firstSign.stderr}');
      final a = zip('a', {'Contents/MacOS/native': binary.readAsBytesSync()});
      final sign = Process.runSync('codesign', [
        '--force',
        '--sign',
        '-',
        '--identifier',
        'other.native',
        binary.path,
      ]);
      expect(sign.exitCode, 0, reason: '${sign.stderr}');
      final b = zip('b', {'Contents/MacOS/native': binary.readAsBytesSync()});
      expect(a.readAsBytesSync(), isNot(b.readAsBytesSync()));
      expect(await differ.changedFiles(a.path, b.path), isEmpty);
    },
    testOn: 'mac-os',
  );
}
