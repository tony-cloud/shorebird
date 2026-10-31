import 'dart:convert';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// Validates ZIP records before their bytes are used for native comparisons.
class AppleZipValidator {
  /// Creates a validator for diagnostic messages for [platform].
  const AppleZipValidator();

  /// Platform name used in validation errors.
  static const platform = 'Apple';

  /// Reads every central directory entry without coalescing duplicate names.
  ZipDirectory readDirectory(InputFileStream input) {
    final directory = ZipDirectory()..read(input);
    if (directory.filePosition < 0 ||
        directory.numberOfThisDisk != 0 ||
        directory.diskWithTheStartOfTheCentralDirectory != 0 ||
        directory.fileHeaders.length !=
            directory.totalCentralDirectoryEntries ||
        directory.totalCentralDirectoryEntriesOnThisDisk !=
            directory.totalCentralDirectoryEntries) {
      throw const FormatException('Invalid $platform ZIP directory');
    }
    return directory;
  }

  /// Validates the complete namespace before Archive can coalesce entries.
  void validate(InputFileStream input, ZipDirectory directory) {
    final entries = <String, ZipFileHeader>{};
    final ranges = <(int, int)>[];
    for (final header in directory.fileHeaders) {
      final name = header.filename;
      final canonical = name.endsWith('/')
          ? name.substring(0, name.length - 1)
          : name;
      if (!_safeName(canonical) || entries.containsKey(canonical)) {
        throw FormatException('Unsafe or duplicate Apple ZIP path', name);
      }
      entries[canonical] = header;
      validateEntry(input, directory, header);
      final local = input.subset(position: header.localHeaderOffset + 26);
      final nameLength = local.readUint16();
      final extraLength = local.readUint16();
      var recordEnd =
          header.localHeaderOffset +
          30 +
          nameLength +
          extraLength +
          header.compressedSize;
      if (header.generalPurposeBitFlag & 8 != 0) {
        final marker = input.subset(position: recordEnd).readUint32();
        recordEnd += marker == 0x08074b50 ? 16 : 12;
      }
      ranges.add((header.localHeaderOffset, recordEnd));
      final content = header.file!.getStream().toUint8List();
      if (content.length != header.uncompressedSize ||
          getCrc32(content) != header.crc32) {
        throw FormatException('Invalid Apple ZIP entry content', name);
      }
      final type = (header.externalFileAttributes >> 16) & 0xf000;
      if ((name.endsWith('/') && (type == 0x8000 || type == 0xa000)) ||
          ((name.endsWith('/') || type == 0x4000) && content.isNotEmpty) ||
          !{0, 0x8000, 0x4000, 0xa000}.contains(type) ||
          (type == 0xa000 && header.versionMadeBy >> 8 != 3)) {
        throw FormatException('Unsupported Apple ZIP file type', name);
      }
    }
    ranges.sort((a, b) => a.$1.compareTo(b.$1));
    for (var i = 1; i < ranges.length; i++) {
      if (ranges[i].$1 < ranges[i - 1].$2) {
        throw const FormatException('Overlapping Apple ZIP entries');
      }
    }
    final links = <String, (String, List<String>)>{};
    for (final entry in entries.entries) {
      final type = (entry.value.externalFileAttributes >> 16) & 0xf000;
      if (type != 0xa000) continue;
      final target = utf8.decode(entry.value.file!.getStream().toUint8List());
      final components = p.posix.split(entry.key);
      final framework = components.indexWhere(
        (part) => part.endsWith('.framework'),
      );
      if (framework < 0 ||
          target.isEmpty ||
          target.contains(r'\') ||
          target.contains('\u0000') ||
          p.posix.isAbsolute(target) ||
          RegExp('^[A-Za-z]:').hasMatch(target)) {
        throw FormatException('Unsafe Apple framework symlink', entry.key);
      }
      links[entry.key] = (
        p.posix.joinAll(components.take(framework + 1)),
        target.split('/'),
      );
    }
    List<String> resolve(
      List<String> initial,
      List<String> pending,
      Set<String> visiting,
      String root,
    ) {
      var current = initial;
      final boundary = p.posix.split(root).length;
      for (final part in pending) {
        final prefix = p.posix.joinAll(current);
        final header = entries[prefix];
        final directoryExists = header == null
            ? entries.keys.any((name) => p.posix.isWithin(prefix, name))
            : (header.externalFileAttributes >> 16) & 0xf000 == 0x4000 ||
                  header.filename.endsWith('/');
        if (!directoryExists) {
          throw const FormatException('Invalid Apple symlink target directory');
        }
        if (part.isEmpty || part == '.') continue;
        if (part == '..') {
          if (current.length <= boundary) {
            throw const FormatException('Escaping Apple framework symlink');
          }
          current.removeLast();
          continue;
        }
        current.add(part);
        final linkPath = p.posix.joinAll(current);
        final link = links[linkPath];
        if (link == null) continue;
        if (!visiting.add(linkPath)) {
          throw const FormatException('Cyclic Apple framework symlink');
        }
        current.removeLast();
        current = resolve(current, link.$2, visiting, root);
        visiting.remove(linkPath);
      }
      return current;
    }

    for (final entry in links.entries) {
      final target = p.posix.joinAll(
        resolve(
          p.posix.split(p.posix.dirname(entry.key)),
          entry.value.$2,
          {entry.key},
          entry.value.$1,
        ),
      );
      if (!p.posix.isWithin(entry.value.$1, target) ||
          (!entries.containsKey(target) &&
              !entries.keys.any((name) => p.posix.isWithin(target, name)))) {
        throw FormatException(
          'Dangling or escaping Apple framework symlink',
          entry.key,
        );
      }
    }
    for (final entry in entries.entries) {
      var parent = p.posix.dirname(entry.key);
      while (parent != '.') {
        final header = entries[parent];
        if (header != null &&
            (((header.externalFileAttributes >> 16) & 0xf000 == 0xa000) ||
                ((header.externalFileAttributes >> 16) & 0xf000 != 0x4000 &&
                    !header.filename.endsWith('/')))) {
          throw FormatException(
            'Apple ZIP entry descends through a file',
            entry.key,
          );
        }
        parent = p.posix.dirname(parent);
      }
    }
  }

  static bool _safeName(String name) =>
      name.isNotEmpty &&
      !name.contains(r'\') &&
      !name.contains('\u0000') &&
      !p.posix.isAbsolute(name) &&
      !RegExp('^[A-Za-z]:').hasMatch(name) &&
      p.posix
          .split(name)
          .every((part) => part.isNotEmpty && part != '.' && part != '..') &&
      p.posix.normalize(name) == name;

  /// Rejects unreadable, encrypted, inconsistent, or unsupported file records.
  void validateEntry(
    InputFileStream input,
    ZipDirectory directory,
    ZipFileHeader header,
  ) {
    Never invalid() => throw FormatException(
      'Invalid or unsupported $platform ZIP entry',
      header.filename,
    );

    if (header.localHeaderOffset < 0 ||
        header.localHeaderOffset + 30 > directory.centralDirectoryOffset ||
        header.diskNumberStart != 0 ||
        (header.generalPurposeBitFlag & 0x41) != 0 ||
        !{0, 8}.contains(header.compressionMethod)) {
      invalid();
    }
    final local = input.subset(position: header.localHeaderOffset);
    if (local.readUint32() != ZipFile.zipSignature) invalid();
    local.readUint16(); // Version needed to extract.
    final flags = local.readUint16();
    final compression = local.readUint16();
    local.readUint32(); // Modification time and date.
    final crc = local.readUint32();
    var compressedSize = local.readUint32();
    var uncompressedSize = local.readUint32();
    final nameLength = local.readUint16();
    final extraLength = local.readUint16();
    final dataOffset = header.localHeaderOffset + 30 + nameLength + extraLength;
    if (dataOffset + header.compressedSize > directory.centralDirectoryOffset ||
        flags != header.generalPurposeBitFlag ||
        compression != header.compressionMethod ||
        local.readString(size: nameLength) != header.filename) {
      invalid();
    }
    final extra = local.readBytes(extraLength);
    if (compressedSize == 0xffffffff || uncompressedSize == 0xffffffff) {
      var foundZip64 = false;
      while (extra.length >= 4) {
        final id = extra.readUint16();
        final length = extra.readUint16();
        if (length > extra.length) invalid();
        final field = extra.readBytes(length);
        if (id != 1) continue;
        if (uncompressedSize == 0xffffffff) {
          if (field.length < 8) invalid();
          uncompressedSize = field.readUint64();
        }
        if (compressedSize == 0xffffffff) {
          if (field.length < 8) invalid();
          compressedSize = field.readUint64();
        }
        foundZip64 = true;
        break;
      }
      if (!foundZip64) invalid();
    }
    final hasDescriptor = flags & 8 != 0;
    if (hasDescriptor) {
      final descriptorOffset = dataOffset + header.compressedSize;
      if (descriptorOffset + 12 > directory.centralDirectoryOffset) invalid();
      final descriptor = input.subset(position: descriptorOffset);
      final signatureOrCrc = descriptor.readUint32();
      if (signatureOrCrc == 0x08074b50 &&
          descriptorOffset + 16 > directory.centralDirectoryOffset) {
        invalid();
      }
      // The archive library reads the descriptor into these fields.
      if ((crc != 0 && crc != header.crc32) ||
          (compressedSize != 0 && compressedSize != header.compressedSize) ||
          (uncompressedSize != 0 &&
              uncompressedSize != header.uncompressedSize)) {
        invalid();
      }
    } else if (crc != header.crc32 ||
        compressedSize != header.compressedSize ||
        uncompressedSize != header.uncompressedSize) {
      invalid();
    }
    final file = header.file;
    if (file == null ||
        file.filename != header.filename ||
        file.crc32 != header.crc32 ||
        file.compressedSize != header.compressedSize ||
        file.uncompressedSize != header.uncompressedSize ||
        file.getStream(decompress: false).length != header.compressedSize) {
      invalid();
    }
  }
}
