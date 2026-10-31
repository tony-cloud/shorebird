import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/archive_analysis/native_zip_validator.dart';

/// Validates the complete namespace of a ZIP containing regular portable files.
///
/// Paths must be unambiguous on case-insensitive filesystems with either path
/// separator. Symlinks, special records and files used as ancestors are
/// rejected.
class PortableZipNamespaceValidator {
  /// Creates a validator with [label] in its diagnostic messages.
  const PortableZipNamespaceValidator(this.label);

  /// Description of the archive used in validation errors.
  final String label;

  /// Validates every record before callers decode or extract any entry.
  ZipDirectory readValidatedDirectory(InputFileStream input) {
    final validator = NativeZipValidator(label);
    // Keep every directory record: ZipDecoder coalesces duplicate names.
    final directory = validator.readDirectory(input);
    final paths = <String, bool>{};
    for (final header in directory.fileHeaders) {
      final path = header.filename.replaceAll(r'\', '/');
      final isDirectory = path.endsWith('/');
      // Conservatively merge Unicode case aliases as well as ASCII names.
      // This is a namespace guard, not an emulation of NTFS normalization.
      final identity = isDirectory
          ? path.substring(0, path.length - 1).toUpperCase()
          : path.toUpperCase();
      if (identity.isEmpty ||
          identity.split('/').any((part) => !_isSafeComponent(part)) ||
          paths.containsKey(identity)) {
        throw FormatException(
          'Unsafe or duplicate $label ZIP path',
          header.filename,
        );
      }
      paths[identity] = isDirectory;
      // A different local name or ancestor can also change the namespace.
      validator.validateEntry(input, directory, header);
      final type = (header.externalFileAttributes >> 16) & 0xf000;
      final attributes = header.externalFileAttributes & 0xffff;
      // DOS volume labels, devices and Windows reparse points are not files.
      final hasSpecialAttributes = attributes & 0x448 != 0;
      if (!{0, 0x8000, 0x4000}.contains(type) ||
          (type == 0x4000 && !isDirectory) ||
          (type == 0x8000 && isDirectory) ||
          (attributes & 0x10 != 0 && !isDirectory) ||
          hasSpecialAttributes ||
          (isDirectory && header.uncompressedSize != 0)) {
        throw FormatException(
          'Unsupported $label ZIP file type',
          header.filename,
        );
      }
    }
    for (final path in paths.keys) {
      var parent = p.posix.dirname(path);
      while (parent != '.') {
        if (paths[parent] == false) {
          throw FormatException('$label ZIP file used as a directory', path);
        }
        parent = p.posix.dirname(parent);
      }
    }
    return directory;
  }

  bool _isSafeComponent(String part) {
    if (part.isEmpty ||
        part == '.' ||
        part == '..' ||
        part.endsWith('.') ||
        part.endsWith(' ') ||
        RegExp(r'[\x00-\x1f<>:"|?*]').hasMatch(part)) {
      return false;
    }
    // Device names remain reserved with an extension (for example, NUL.txt).
    final stem = part
        .split('.')
        .first
        .replaceFirst(RegExp(r' +$'), '')
        .toLowerCase();
    return !RegExp(
      r'^(con|prn|aux|nul|conin\$|conout\$|clock\$|com[1-9¹²³]|lpt[1-9¹²³])$',
    ).hasMatch(stem);
  }
}
