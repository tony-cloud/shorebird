import 'package:archive/archive_io.dart';
import 'package:shorebird_cli/src/archive_analysis/release_supplement_validator.dart';
import 'package:test/test.dart';

import '../helpers.dart';

void main() {
  useTempWorkingDirectory();
  const validator = ReleaseSupplementValidator();
  const content = [0, 1, 128, 255];

  ZipFileHeader header({int? size, int? crc}) => ZipFileHeader()
    ..filename = 'baseline.bytecode'
    ..uncompressedSize = size ?? content.length
    ..crc32 = crc ?? getCrc32(content);

  group(ReleaseSupplementValidator, () {
    test('preserves verified regular supplement bytes', () {
      final entry = ArchiveFile.bytes('baseline.bytecode', content);
      expect(validator.readValidatedContent(entry, header()), content);
    });

    for (final size in [content.length - 1, content.length + 1]) {
      test('rejects decompressed length disagreement $size', () {
        final entry = ArchiveFile.bytes('baseline.bytecode', content);
        expect(
          () => validator.readValidatedContent(entry, header(size: size)),
          throwsFormatException,
        );
      });
    }

    test('rejects decompressed CRC disagreement', () {
      final entry = ArchiveFile.bytes('baseline.bytecode', content);
      expect(
        () => validator.readValidatedContent(
          entry,
          header(crc: getCrc32(content) ^ 1),
        ),
        throwsFormatException,
      );
    });

    test('accepts empty regular file content', () {
      final entry = ArchiveFile.bytes('empty.bin', []);
      expect(
        validator.readValidatedContent(
          entry,
          ZipFileHeader()
            ..uncompressedSize = 0
            ..crc32 = 0,
        ),
        isEmpty,
      );
    });
  });
}
