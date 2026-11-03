import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:open_aot_patch_tools/open_aot_patch_tools.dart';
import 'package:test/test.dart';

Uint8List _vmcode({
  int links = 2,
  List<int> elf = const [1, 2, 3, 4, 5],
  int linked = 60,
  int code = 100,
  int version = 1,
}) {
  final elfOffset = 16384;
  final out = Uint8List(elfOffset + elf.length);
  final d = ByteData.sublistView(out)
    ..setUint32(8, version, Endian.little)
    ..setUint32(12, elfOffset, Endian.little)
    ..setUint64(16, elfOffset, Endian.little)
    ..setUint64(24, elf.length, Endian.little)
    ..setUint32(32, links, Endian.little)
    ..setUint32(36, 16, Endian.little)
    ..setUint32(40, 128, Endian.little)
    ..setUint32(112, 4096, Endian.little)
    ..setUint32(116, 8192, Endian.little)
    ..setUint32(120, linked, Endian.little)
    ..setUint32(124, code, Endian.little);
  out
    ..setAll(0, VmcodeHeader.magic)
    ..setAll(48, List.filled(32, 0xab))
    ..setAll(80, sha256.convert(elf).bytes)
    ..setAll(elfOffset, elf);
  return out;
}

void main() {
  test('parses a well-formed header', () {
    final h = VmcodeHeader.parse(_vmcode());
    expect(h.linkCount, 2);
    expect(h.releaseTextSha256, 'ab' * 32);
    expect(h.releaseTextSize, 4096);
    expect(h.linkPercent, 60);
    expect(h.elfSize, 5);
  });

  test('rejects bad magic, version, geometry and counts', () {
    final bad = _vmcode()..[0] = 0;
    expect(() => VmcodeHeader.parse(bad), throwsFormatException);
    expect(
      () => VmcodeHeader.parse(_vmcode(version: 2)),
      throwsFormatException,
    );
    expect(
      () => VmcodeHeader.parse(_vmcode(linked: 101)),
      throwsFormatException,
    );
    expect(
      () => VmcodeHeader.parse(_vmcode().sublist(0, 16000)),
      throwsFormatException,
    );
    expect(() => VmcodeHeader.parse(Uint8List(64)), throwsFormatException);
  });

  test('readVerified checks the embedded ELF hash', () {
    final dir = Directory.systemTemp.createTempSync('vmcode_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final good = File('${dir.path}/good')..writeAsBytesSync(_vmcode());
    expect(VmcodeHeader.readVerified(good).elfSha256, isNotEmpty);
    final tampered = _vmcode();
    tampered[tampered.length - 1] ^= 1;
    final bad = File('${dir.path}/bad')..writeAsBytesSync(tampered);
    expect(() => VmcodeHeader.readVerified(bad), throwsFormatException);
  });
}
