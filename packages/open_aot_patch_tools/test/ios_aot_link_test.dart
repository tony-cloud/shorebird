import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:open_aot_patch_tools/open_aot_patch_tools.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _head =
    '#osb-link-info 2\n'
    'id\tsnapshot_hash\taaaa\n'
    'id\tfeatures\tproduct arm64 ios\n'
    'meta\tnum_cids\t10\n'
    'meta\tnum_cids\t10\n'
    'class\t176\tpackage:x/x.dart::X\t16\n'
    'code\t_kDartSnapshotText\t128\t252\tfn:package:x/x.dart::f#0/0\n'
    'meta\ttext_image_size\t4096\n';
final _textSha = sha256.convert(utf8.encode('text')).toString();

void main() {
  late Directory dir;

  Directory fixture({bool dd = false}) {
    final d = Directory.systemTemp.createTempSync('aot_link_test');
    File(p.join(d.path, 'App.link')).writeAsStringSync(_head);
    File(p.join(d.path, 'app.dill')).writeAsStringSync('kernel');
    File(p.join(d.path, 'App.macho')).writeAsStringSync('macho');
    if (dd) File(p.join(d.path, 'App.dd')).writeAsStringSync('# DD\nfoo\n');
    return d;
  }

  AotLinkSupplement write(Directory d, {int dd = 0}) => AotLinkSupplement.write(
    d,
    releaseTextSha256: _textSha,
    textImageSize: 4096,
    ddMaxBytes: dd,
    ddPackages: dd > 0 ? ['my_app'] : const [],
  );

  setUp(() => dir = fixture());
  tearDown(() => dir.deleteSync(recursive: true));

  test('write records hashes, identity and the release text hash', () {
    final s = write(dir);
    expect(s.snapshotHash, 'aaaa');
    expect(s.features, 'product arm64 ios');
    expect(s.releaseTextSha256, _textSha);
    expect(s.usesDd, isFalse);
    expect(s.files.keys, ['App.link', 'App.macho', 'app.dill']);
    expect(
      s.files['app.dill']!.sha256,
      sha256.convert(utf8.encode('kernel')).toString(),
    );
    final again = AotLinkSupplement.verify(dir);
    expect(again.releaseTextSha256, _textSha);
    expect(again.textImageSize, 4096);
  });

  test('a DD release lists App.dd and the packages', () {
    dir.deleteSync(recursive: true);
    dir = fixture(dd: true);
    final s = write(dir, dd: 10000);
    expect(s.usesDd, isTrue);
    final v = AotLinkSupplement.verify(dir);
    expect(v.usesDd, isTrue);
    expect(v.ddMaxBytes, 10000);
    expect(v.ddPackages, ['my_app']);
  });

  test('write refuses DD files without DD, and DD without a file', () {
    dir.deleteSync(recursive: true);
    dir = fixture(dd: true);
    expect(() => write(dir), throwsA(isA<AotLinkSupplementException>()));
    dir.deleteSync(recursive: true);
    dir = fixture();
    expect(() => write(dir, dd: 5), throwsA(isA<AotLinkSupplementException>()));
  });

  test('write refuses a sidecar from another binary and stray files', () {
    expect(
      () => AotLinkSupplement.write(
        dir,
        releaseTextSha256: _textSha,
        textImageSize: 8192,
      ),
      throwsA(isA<AotLinkSupplementException>()),
    );
    File(p.join(dir.path, 'out.aot')).writeAsStringSync('x');
    expect(() => write(dir), throwsA(isA<AotLinkSupplementException>()));
  });

  group('verify rejects', () {
    setUp(() => write(dir));

    test('a tampered file', () {
      File(p.join(dir.path, 'App.macho')).writeAsStringSync('MACHO');
      expect(
        () => AotLinkSupplement.verify(dir),
        throwsA(
          isA<AotLinkSupplementException>().having(
            (e) => e.message,
            'message',
            contains('App.macho'),
          ),
        ),
      );
    });

    test('a replaced sidecar even with a matching size', () {
      File(p.join(dir.path, 'App.link')).writeAsStringSync(
        _head.replaceFirst('aaaa', 'bbbb'),
      );
      expect(
        () => AotLinkSupplement.verify(dir),
        throwsA(isA<AotLinkSupplementException>()),
      );
    });

    test('a missing file', () {
      File(p.join(dir.path, 'app.dill')).deleteSync();
      expect(
        () => AotLinkSupplement.verify(dir),
        throwsA(isA<AotLinkSupplementException>()),
      );
    });

    test('an unlisted file or a nested directory', () {
      File(p.join(dir.path, 'extra.bin')).writeAsStringSync('x');
      expect(
        () => AotLinkSupplement.verify(dir),
        throwsA(isA<AotLinkSupplementException>()),
      );
      File(p.join(dir.path, 'extra.bin')).deleteSync();
      Directory(p.join(dir.path, 'App.framework')).createSync();
      expect(
        () => AotLinkSupplement.verify(dir),
        throwsA(isA<AotLinkSupplementException>()),
      );
    });

    test('a manifest from another profile or version', () {
      final f = File(p.join(dir.path, AotLinkSupplement.manifestFileName));
      final json = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
      f.writeAsStringSync(jsonEncode({...json, 'version': 2}));
      expect(
        () => AotLinkSupplement.verify(dir),
        throwsA(isA<AotLinkSupplementException>()),
      );
      f.writeAsStringSync(jsonEncode({...json, 'profile': 'interpreter-body'}));
      expect(
        () => AotLinkSupplement.verify(dir),
        throwsA(isA<AotLinkSupplementException>()),
      );
    });

    test('a manifest that hides DD from the files', () {
      final f = File(p.join(dir.path, AotLinkSupplement.manifestFileName));
      final json = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
      (json['dd']! as Map<String, Object?>)['max_bytes'] = 10000;
      f.writeAsStringSync(jsonEncode(json));
      expect(
        () => AotLinkSupplement.verify(dir),
        throwsA(isA<AotLinkSupplementException>()),
      );
    });

    test('a directory without a manifest', () {
      File(p.join(dir.path, AotLinkSupplement.manifestFileName)).deleteSync();
      expect(
        () => AotLinkSupplement.verify(dir),
        throwsA(isA<AotLinkSupplementException>()),
      );
    });
  });

  test('stamp keeps the file hashes valid', () {
    write(dir);
    AotLinkSupplement.stamp(dir, releaseId: 7, appBuildId: '1.0.0+1');
    final v = AotLinkSupplement.verify(dir);
    expect(v.releaseId, 7);
    expect(v.appBuildId, '1.0.0+1');
  });

  group('IosLinkerFailure', () {
    test('maps the documented exit codes', () {
      expect(IosLinkerFailure.fromExitCode(2), IosLinkerFailure.unlinkedStub);
      expect(IosLinkerFailure.fromExitCode(3), IosLinkerFailure.belowMinimum);
      expect(
        IosLinkerFailure.fromExitCode(4),
        IosLinkerFailure.sidecarMismatch,
      );
      expect(IosLinkerFailure.fromExitCode(1), IosLinkerFailure.checkFailed);
      expect(IosLinkerFailure.fromExitCode(5), IosLinkerFailure.gateBudget);
      expect(IosLinkerFailure.fromExitCode(70), isNull);
    });

    test('messages say what to do', () {
      expect(
        IosLinkerFailure.unlinkedStub.describe(),
        contains('same Flutter'),
      );
      expect(
        IosLinkerFailure.belowMinimum.describe(failBelow: 35),
        allOf(contains('35%'), contains('--min-link-percentage')),
      );
      expect(
        IosLinkerFailure.sidecarMismatch.describe(detail: 'x differs'),
        contains('x differs'),
      );
    });
  });

  test('AotLinkPolicy defaults to warn below 90 and fail below 20', () {
    const policy = AotLinkPolicy();
    expect(policy.warnBelow, 90);
    expect(policy.failBelow, 20);
  });
}
