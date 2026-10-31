import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/archive_analysis/portable_zip_namespace_validator.dart';
import 'package:test/test.dart';

import '../helpers.dart';

void main() {
  useTempWorkingDirectory();
  const validator = PortableZipNamespaceValidator('Release supplement');

  // Rejection tests only read ZIP records. They never invoke extraction.
  void validate(List<String> names, {int attributes = 0}) {
    final root = createSystemTemp();
    final file = File(p.join(root.path, 'supplement.zip'))
      ..writeAsBytesSync(_zip(names, attributes: attributes));
    final input = InputFileStream(file.path);
    try {
      validator.readValidatedDirectory(input);
    } finally {
      input.closeSync();
    }
  }

  group(PortableZipNamespaceValidator, () {
    for (final path in [
      '',
      '/baseline.bytecode',
      r'\baseline.bytecode',
      r'\\server\share\baseline.bytecode',
      'C:/baseline.bytecode',
      'C:baseline.bytecode',
      '../baseline.bytecode',
      'future/../baseline.bytecode',
      r'future\..\baseline.bytecode',
      'future/./metadata',
      'future//metadata',
      'future/metadata.',
      'future/metadata ',
      'future./metadata',
      'future /metadata',
      'baseline.bytecode:stream',
      'baseline\x00.bytecode',
      'line\nbreak',
      'meta<data',
      'meta>data',
      'meta"data',
      'meta|data',
      'meta?data',
      'meta*data',
      'NUL.txt',
      'future/COM1.bin',
      'LPT²/data',
    ]) {
      test('rejects unsafe path ${jsonEncode(path)}', () {
        expect(
          () => validate([path]),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('Release supplement ZIP'),
            ),
          ),
        );
      });
    }

    for (final names in [
      ['baseline.json', 'baseline.json'],
      ['baseline.json', 'BASELINE.JSON'],
      ['future/metadata', r'FUTURE\METADATA'],
      ['σ/data', 'ς/DATA'],
      ['future/', r'FUTURE\'],
      ['future', 'FUTURE/'],
      ['future', 'FUTURE/nested/metadata'],
      ['FUTURE/nested/metadata', 'future'],
    ]) {
      test('rejects duplicate identities or file ancestors $names', () {
        expect(() => validate(names), throwsFormatException);
      });
    }

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
      test('rejects special record $attributes', () {
        expect(
          () => validate(['baseline.bytecode'], attributes: attributes),
          throwsFormatException,
        );
      });
    }

    test('accepts regular portable files and explicit or implicit parents', () {
      expect(
        () => validate([
          'obfuscation_map.json',
          'baseline.bytecode',
          'baseline.json',
          'App.ct.link',
          'App.class_table.json',
          'App.ft.link',
          'App.field_table.json',
          'App.dt.link',
          'App.dispatch_table.json',
          'App.dd.link',
          'App.dd_callers.link',
          'App.dd_resolution.tsv',
          'future/',
          'future/nested/metadata.bin',
        ]),
        returnsNormally,
      );
    });
  });
}

// Preserve all directory records, including identical names, in these fixtures.
List<int> _zip(List<String> names, {required int attributes}) {
  final output = OutputMemoryStream();
  final offsets = <int>[];
  for (final name in names) {
    final bytes = utf8.encode(name);
    offsets.add(output.length);
    output
      ..writeUint32(0x04034b50)
      ..writeUint16(20)
      ..writeUint16(0)
      ..writeUint16(0)
      ..writeUint32(0)
      ..writeUint32(0)
      ..writeUint32(0)
      ..writeUint32(0)
      ..writeUint16(bytes.length)
      ..writeUint16(0)
      ..writeBytes(bytes);
  }
  final centralOffset = output.length;
  for (var i = 0; i < names.length; i++) {
    final bytes = utf8.encode(names[i]);
    output
      ..writeUint32(0x02014b50)
      ..writeUint16(20)
      ..writeUint16(20)
      ..writeUint16(0)
      ..writeUint16(0)
      ..writeUint32(0)
      ..writeUint32(0)
      ..writeUint32(0)
      ..writeUint32(0)
      ..writeUint16(bytes.length)
      ..writeUint16(0)
      ..writeUint16(0)
      ..writeUint16(0)
      ..writeUint16(0)
      ..writeUint32(attributes)
      ..writeUint32(offsets[i])
      ..writeBytes(bytes);
  }
  final centralSize = output.length - centralOffset;
  output
    ..writeUint32(0x06054b50)
    ..writeUint16(0)
    ..writeUint16(0)
    ..writeUint16(names.length)
    ..writeUint16(names.length)
    ..writeUint32(centralSize)
    ..writeUint32(centralOffset)
    ..writeUint16(0);
  return output.getBytes();
}
