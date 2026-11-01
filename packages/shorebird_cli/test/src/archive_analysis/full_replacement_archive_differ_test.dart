import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:mocktail/mocktail.dart';
import 'package:open_aot_patch_tools/open_aot_patch_tools.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/archive_analysis/full_replacement_archive_differ.dart';
import 'package:shorebird_cli/src/archive_analysis/shorebird_native_assets_descriptor.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/patch_diff_checker.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:test/test.dart';

import '../helpers.dart';
import '../mocks.dart';
import '../platform/apple/macho_fixture.dart' show image;

const _app = 'Products/Applications/Runner.app';
const _assets = '$_app/Frameworks/App.framework/flutter_assets';
const _policyPath = '$_assets/shorebird.yaml';
const _basePath = '$_assets/shorebird_replacement_base.sbr';
const _descriptorPath = '$_assets/shorebird_native_assets.json';
const _root = 'package:app/main.dart';

void main() {
  useTempWorkingDirectory();
  late Directory temp;
  late List<int> released;
  late List<int> comparison;
  late FullReplacementArchiveDiffer differ;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('replacement_archive_differ.');
    released = _baseline(0);
    comparison = _baseline(1);
    differ = FullReplacementArchiveDiffer(
      releaseBaseHash: sha256Hex(released),
      comparisonBaseHash: sha256Hex(comparison),
    );
  });

  tearDown(() => temp.deleteSync(recursive: true));

  File archive(
    String name,
    List<int> baseline, {
    Map<String, Object?> policyOverrides = const {},
    Map<String, List<int>> assets = const {},
    Set<String> omitted = const {},
    List<MapEntry<String, List<int>>> extra = const [],
    String? policyText,
  }) {
    final entries = <String, List<int>>{
      _policyPath: utf8.encode(
        policyText ?? jsonEncode(_policy(baseline)..addAll(policyOverrides)),
      ),
      _basePath: baseline,
      _descriptorPath: _descriptor(),
      '$_assets/assets/config.json': utf8.encode('app asset'),
      '$_app/Runner': utf8.encode('native runner'),
      '$_app/Frameworks/Plugin.framework/Plugin': utf8.encode('plugin'),
      'Podfile.lock': utf8.encode('pod dependencies'),
      ...assets,
    }..removeWhere((key, _) => omitted.contains(key));
    return _writeArchive(temp, name, [...entries.entries, ...extra]);
  }

  Future<DiffStatus> check(
    File old,
    File updated, {
    bool allowNative = false,
  }) {
    final logger = MockShorebirdLogger();
    final environment = MockShorebirdEnv();
    when(() => logger.progress(any())).thenReturn(MockProgress());
    when(() => environment.canAcceptUserInput).thenReturn(false);
    return runScoped(
      () => PatchDiffChecker().confirmUnpatchableDiffsIfNecessary(
        localArchive: updated,
        releaseArchive: old,
        archiveDiffer: differ,
        allowAssetChanges: true,
        allowNativeChanges: allowNative,
      ),
      values: {
        loggerRef.overrideWith(() => logger),
        shorebirdEnvRef.overrideWith(() => environment),
      },
    );
  }

  test(
    'only changed generated baseline bytes produce no asset differences',
    () async {
      final old = archive('old', released);
      final updated = archive('new', comparison);
      final changes = await differ.changedFiles(old.path, updated.path);
      expect(changes, isEmpty);
      expect(differ.containsPotentiallyBreakingAssetDiffs(changes), isFalse);
      expect(differ.containsPotentiallyBreakingNativeDiffs(changes), isFalse);
    },
  );

  for (final path in [
    '$_app/Frameworks/Plugin.framework/Plugin',
    '$_app/Frameworks/Flutter.framework/Flutter',
    '$_app/Runner',
    '$_app/Helpers/suffixless',
  ]) {
    test('full profile retains isolated native change $path', () async {
      final old = archive('old', released, assets: {path: image()});
      final updated = archive(
        'new',
        comparison,
        assets: {path: image()..last = 7},
      );
      final changes = await differ.changedFiles(old.path, updated.path);
      expect(changes.changedPaths, {path});
      expect(differ.nativeFileSetDiff(changes).changedPaths, {path});
    });
  }
  test('full profile permits changing generated App snapshot bytes', () async {
    const path = '$_app/Frameworks/App.framework/App';
    final old = archive('old', released, assets: {path: image()});
    final updated = archive(
      'new',
      comparison,
      assets: {path: image()..last = 7},
    );
    final changes = await differ.changedFiles(old.path, updated.path);
    expect(changes.changedPaths, {path});
    expect(differ.nativeFileSetDiff(changes), isEmpty);
    expect(differ.assetsFileSetDiff(changes), isEmpty);
  });

  group('native asset mappings', () {
    const mappingPath = '$_assets/NativeAssetsManifest.json';
    const appPath = '$_app/Frameworks/App.framework/App';

    List<int> mapping(String library) => utf8.encode(
      jsonEncode({
        'format-version': [1, 0, 0],
        'native-assets': {
          'ios_arm64': {
            'package:example/native.dart': ['absolute', library],
          },
        },
      }),
    );

    for (final operation in ['changed', 'added', 'removed']) {
      for (final allowNative in [false, true]) {
        test('$operation mapping with native override $allowNative', () async {
          final old = archive(
            'old',
            released,
            assets: {
              appPath: image(),
              if (operation != 'added')
                mappingPath: mapping('Plugin.framework/Plugin'),
            },
          );
          final updated = archive(
            'new',
            comparison,
            assets: {
              appPath: image()..last = 7,
              if (operation != 'removed')
                mappingPath: mapping('Other.framework/Other'),
            },
          );
          if (allowNative) {
            final status = await check(old, updated, allowNative: true);
            expect(status.hasNativeChanges, isTrue);
            expect(status.hasAssetChanges, isFalse);
          } else {
            await expectLater(
              check(old, updated),
              throwsA(isA<UnpatchableChangeException>()),
            );
          }
          final changes = await differ.changedFiles(old.path, updated.path);
          final native = differ.nativeFileSetDiff(changes);
          expect(
            native.changedPaths,
            operation == 'changed' ? {mappingPath} : isEmpty,
          );
          expect(
            native.addedPaths,
            operation == 'added' ? {mappingPath} : isEmpty,
          );
          expect(
            native.removedPaths,
            operation == 'removed' ? {mappingPath} : isEmpty,
          );
          expect(differ.assetsFileSetDiff(changes), isEmpty);
        });
      }
    }

    test('same mapping permits changed generated App and baseline', () async {
      final assets = {mappingPath: mapping('Plugin.framework/Plugin')};
      final old = archive(
        'old',
        released,
        assets: {...assets, appPath: image()},
      );
      final updated = archive(
        'new',
        comparison,
        assets: {...assets, appPath: image()..last = 7},
      );
      final status = await check(old, updated);
      expect(status.hasNativeChanges, isFalse);
      expect(status.hasAssetChanges, isFalse);
      expect((await differ.changedFiles(old.path, updated.path)).changedPaths, {
        appPath,
      });
    });

    test('compares mapping bytes without JSON normalization', () async {
      final bytes = mapping('Plugin.framework/Plugin');
      final old = archive('old', released, assets: {mappingPath: bytes});
      final updated = archive(
        'new',
        comparison,
        assets: {
          mappingPath: [...bytes, 0x0a],
        },
      );
      await expectLater(
        check(old, updated),
        throwsA(isA<UnpatchableChangeException>()),
      );
    });

    test('classifies only the exact asset-root mapping filename', () {
      for (final path in [
        mappingPath,
        'flutter_assets/NativeAssetsManifest.json',
        'Contents/Frameworks/App.framework/Resources/flutter_assets/NativeAssetsManifest.json',
      ]) {
        expect(differ.isNativeFilePath(path), isTrue, reason: path);
        expect(differ.isAssetFilePath(path), isFalse, reason: path);
      }
      for (final path in [
        '$_assets/assets/NativeAssetsManifest.json',
        '$_assets/NativeAssetsManifest.json.bak',
        '$_assets/nativeassetsmanifest.json',
      ]) {
        expect(differ.isNativeFilePath(path), isFalse, reason: path);
        expect(differ.isAssetFilePath(path), isTrue, reason: path);
      }
      expect(differ.isNativeFilePath('NativeAssetsManifest.json'), isFalse);
    });
  });

  group('legacy native mapping provenance', () {
    for (final missingRelease in [false, true]) {
      for (final missingComparison in [false, true]) {
        if (!missingRelease && !missingComparison) continue;
        for (final allowNative in [false, true]) {
          test('missing release=$missingRelease comparison=$missingComparison '
              'native override=$allowNative', () async {
            final old = archive(
              'old',
              released,
              omitted: {if (missingRelease) _descriptorPath},
            );
            final updated = archive(
              'new',
              comparison,
              omitted: {if (missingComparison) _descriptorPath},
            );
            final changes = await differ.changedFiles(old.path, updated.path);
            expect(changes.changedPaths, {_descriptorPath});
            expect(changes.addedPaths, isEmpty);
            expect(changes.removedPaths, isEmpty);
            final native = differ.nativeFileSetDiff(changes);
            expect(native.prettyString, contains('provenance is unknown'));
            expect(native.prettyString, contains('equality is unverified'));
            expect(native.prettyString, contains(_descriptorPath));
            expect(native.prettyString, isNot(contains('Changed files')));
            expect(differ.assetsFileSetDiff(changes), isEmpty);
            if (allowNative) {
              final status = await check(old, updated, allowNative: true);
              expect(status.hasNativeChanges, isTrue);
              expect(status.hasAssetChanges, isFalse);
            } else {
              await expectLater(
                check(old, updated),
                throwsA(isA<UnpatchableChangeException>()),
              );
            }
          });
        }
      }
    }

    for (final mappingHash in ['1' * 64, sha256Hex(utf8.encode('{}'))]) {
      test(
        'mapping digest or absent-to-present transition is native $mappingHash',
        () async {
          final old = archive('old', released);
          final updated = archive(
            'new',
            comparison,
            assets: {_descriptorPath: _descriptor(mappingHash: mappingHash)},
          );
          final changes = await differ.changedFiles(old.path, updated.path);
          expect(differ.nativeFileSetDiff(changes).changedPaths, {
            _descriptorPath,
          });
          expect(differ.assetsFileSetDiff(changes), isEmpty);
          await expectLater(
            check(old, updated),
            throwsA(isA<UnpatchableChangeException>()),
          );
          final status = await check(old, updated, allowNative: true);
          expect(status.hasNativeChanges, isTrue);
          expect(status.hasAssetChanges, isFalse);
        },
      );
    }

    test('different present-carrier mapping digests remain native', () async {
      final old = archive(
        'old',
        released,
        assets: {_descriptorPath: _descriptor(mappingHash: '0' * 64)},
      );
      final updated = archive(
        'new',
        comparison,
        assets: {_descriptorPath: _descriptor(mappingHash: '1' * 64)},
      );
      await expectLater(
        check(old, updated),
        throwsA(isA<UnpatchableChangeException>()),
      );
      expect(
        differ
            .nativeFileSetDiff(
              await differ.changedFiles(old.path, updated.path),
            )
            .changedPaths,
        {_descriptorPath},
      );
    });

    test(
      'same mapping allows structural App/base changes and optional final LF',
      () async {
        const appPath = '$_app/Frameworks/App.framework/App';
        final hash = sha256Hex(utf8.encode('{}'));
        final old = archive(
          'old',
          released,
          assets: {
            _descriptorPath: _descriptor(mappingHash: hash),
            appPath: image(),
          },
        );
        final updated = archive(
          'new',
          comparison,
          assets: {
            _descriptorPath: _descriptor(mappingHash: hash, newline: false),
            appPath: image()..last = 7,
          },
        );
        final status = await check(old, updated);
        expect(status.hasNativeChanges, isFalse);
        expect(status.hasAssetChanges, isFalse);
        expect(
          (await differ.changedFiles(old.path, updated.path)).changedPaths,
          {appPath},
        );
      },
    );

    final valid = utf8.decode(_descriptor(newline: false));
    final malformed = <String, String>{
      'schema': '{"schema":0,"target":"ios_arm64","carrier_present":false}',
      'numeric schema type':
          '{"schema":1.0,"target":"ios_arm64","carrier_present":false}',
      'target': '{"schema":1,"target":"macos_arm64","carrier_present":false}',
      'carrier type':
          '{"schema":1,"target":"ios_arm64","carrier_present":"false"}',
      'missing digest':
          '{"schema":1,"target":"ios_arm64","carrier_present":true}',
      'uppercase digest': utf8.decode(_descriptor(mappingHash: 'A' * 64)),
      'short digest': utf8.decode(_descriptor(mappingHash: 'a' * 63)),
      'null digest':
          '{"schema":1,"target":"ios_arm64","carrier_present":true,'
          '"mapping_sha256":null}',
      'absent carrier digest':
          '{"schema":1,"target":"ios_arm64","carrier_present":false,'
          '"mapping_sha256":"${'a' * 64}"}',
      'extra field':
          '{"schema":1,"target":"ios_arm64","carrier_present":false,'
          '"extra":true}',
      'reordered keys':
          '{"target":"ios_arm64","schema":1,"carrier_present":false}',
      'duplicate schema':
          '{"schema":1,"schema":1,"target":"ios_arm64",'
          '"carrier_present":false}',
      'duplicate carrier':
          '{"schema":1,"target":"ios_arm64","carrier_present":true,'
          '"carrier_present":false}',
      'array': '[]',
      'invalid JSON': '{',
      'two final newlines': '$valid\n\n',
      'CRLF': '$valid\r\n',
      'leading whitespace': ' $valid',
      'BOM': '\ufeff$valid',
      'oversized': '$valid${' ' * 4096}',
    };
    for (final entry in malformed.entries) {
      test('rejects malformed descriptor ${entry.key}', () async {
        final old = archive('old', released);
        final updated = archive(
          'new',
          comparison,
          assets: {_descriptorPath: utf8.encode(entry.value)},
        );
        await expectLater(
          differ.changedFiles(old.path, updated.path),
          throwsFormatException,
        );
      });
    }

    test('malformed release descriptor is never treated as missing', () async {
      final old = archive(
        'old',
        released,
        assets: {
          _descriptorPath: utf8.encode(
            '{"schema":1,"target":"macos_arm64",'
            '"carrier_present":false}',
          ),
        },
      );
      final updated = archive('new', comparison);
      await expectLater(
        check(old, updated, allowNative: true),
        throwsFormatException,
      );
    });

    test('rejects duplicate descriptor ZIP entries', () async {
      final old = archive('old', released);
      final updated = archive(
        'new',
        comparison,
        extra: [MapEntry(_descriptorPath, _descriptor())],
      );
      await expectLater(
        differ.changedFiles(old.path, updated.path),
        throwsFormatException,
      );
    });

    test('descriptor parser requires regular bounded files', () {
      for (final file in [
        ArchiveFile.directory(_descriptorPath),
        ArchiveFile.symlink(_descriptorPath, 'other.json'),
        ArchiveFile(_descriptorPath, 0, []),
      ]) {
        expect(
          () => ShorebirdNativeAssetsDescriptor.canonicalBody(file),
          throwsFormatException,
        );
      }
    });

    test('classifies only exact descriptor asset-root paths', () {
      for (final path in [
        _descriptorPath,
        'flutter_assets/shorebird_native_assets.json',
      ]) {
        expect(differ.isNativeFilePath(path), isTrue);
        expect(differ.isAssetFilePath(path), isFalse);
      }
      for (final path in [
        '$_assets/assets/shorebird_native_assets.json',
        '$_assets/shorebird_native_assets.json.bak',
      ]) {
        expect(differ.isNativeFilePath(path), isFalse);
        expect(differ.isAssetFilePath(path), isTrue);
      }
    });
  });

  test(
    'retains real app asset, native runner, plugin and pod changes',
    () async {
      final old = archive('old', released);
      final updated = archive(
        'new',
        comparison,
        assets: {
          '$_assets/assets/config.json': utf8.encode('changed app asset'),
          '$_app/Runner': utf8.encode('changed native runner'),
          '$_app/Frameworks/Plugin.framework/Plugin': utf8.encode(
            'changed plugin',
          ),
          'Podfile.lock': utf8.encode('changed pod dependencies'),
        },
      );
      final changes = await differ.changedFiles(old.path, updated.path);
      expect(changes.changedPaths, {
        '$_assets/assets/config.json',
        '$_app/Runner',
        '$_app/Frameworks/Plugin.framework/Plugin',
        'Podfile.lock',
      });
      expect(differ.containsPotentiallyBreakingAssetDiffs(changes), isTrue);
      expect(differ.containsPotentiallyBreakingNativeDiffs(changes), isTrue);
    },
  );

  test(
    'retains same-basename app files outside the owned asset paths',
    () async {
      const outside = '$_app/shorebird_replacement_base.sbr';
      const nested = '$_assets/assets/shorebird_replacement_base.sbr';
      final old = archive(
        'old',
        released,
        assets: {
          outside: [1],
          nested: [1],
        },
      );
      final updated = archive(
        'new',
        comparison,
        assets: {
          outside: [2],
          nested: [2],
        },
      );
      final changes = await differ.changedFiles(old.path, updated.path);
      expect(changes.changedPaths, {outside, nested});
      expect(differ.containsPotentiallyBreakingAssetDiffs(changes), isTrue);
    },
  );

  test('retains added and removed real assets', () async {
    final old = archive('old', released);
    final updated = archive(
      'new',
      comparison,
      omitted: {'$_assets/assets/config.json'},
      assets: {'$_assets/assets/new.txt': utf8.encode('new')},
    );
    final changes = await differ.changedFiles(old.path, updated.path);
    expect(changes.addedPaths, {'$_assets/assets/new.txt'});
    expect(changes.removedPaths, {'$_assets/assets/config.json'});
    expect(changes.changedPaths, isEmpty);
  });

  test(
    'normalizes YAML map order and formatting but retains every other field',
    () async {
      final oldPolicy = _policy(released)
        ..['extra'] = {
          'a': 1,
          'b': [true, 'x'],
        };
      final newPolicy = _policy(comparison)
        ..['extra'] = {
          'b': [true, 'x'],
          'a': 1,
        };
      final old = archive('old', released, policyText: jsonEncode(oldPolicy));
      final equivalent = archive(
        'equivalent',
        comparison,
        policyText: const JsonEncoder.withIndent('  ').convert(newPolicy),
      );
      expect(await differ.changedFiles(old.path, equivalent.path), isEmpty);

      final changed = archive(
        'changed',
        comparison,
        policyOverrides: {
          'extra': {
            'a': 2,
            'b': [true, 'x'],
          },
        },
      );
      final changes = await differ.changedFiles(old.path, changed.path);
      expect(changes.changedPaths, {_policyPath});
      expect(differ.containsPotentiallyBreakingAssetDiffs(changes), isTrue);
    },
  );

  test('retains changes to signing policy and app identity', () async {
    final old = archive('old', released);
    for (final override in [
      {'patch_public_key': 'another key'},
      {'app_id': 'another app'},
      {'patch_verification': 'install_only'},
    ]) {
      final updated = archive('new', comparison, policyOverrides: override);
      expect((await differ.changedFiles(old.path, updated.path)).changedPaths, {
        _policyPath,
      });
    }
  });

  final invalidPolicies = <String, Map<String, Object?>>{
    'disabled full replacement': {'aot_patch_full_replacement': false},
    'string full replacement': {'aot_patch_full_replacement': 'true'},
    'wrong runtime': {'aot_patch_runtime_mode': 'native-aot'},
    'additive structural profile': {'aot_patch_structural_updates': true},
    'invalid host': {'aot_patch_host_abi': 'invalid'},
    'host differs from wrapper': {'aot_patch_host_abi': 'ff' * 32},
    'unexpected asset name': {'aot_patch_replacement_base': 'other.sbr'},
    'wrong YAML base hash': {'aot_patch_base_snapshot_hash': 'ff' * 32},
  };
  for (final entry in invalidPolicies.entries) {
    test('rejects ${entry.key}', () async {
      final old = archive('old', released);
      final updated = archive('new', comparison, policyOverrides: entry.value);
      await expectLater(
        differ.changedFiles(old.path, updated.path),
        throwsFormatException,
      );
    });
  }

  test(
    'checks actual baseline asset hash against the expected archive hash',
    () async {
      final old = archive('old', released);
      final updated = archive('new', comparison, assets: {_basePath: released});
      await expectLater(
        differ.changedFiles(old.path, updated.path),
        throwsFormatException,
      );
    },
  );

  test('checks release and comparison expected hash separately', () async {
    final old = archive('old', released);
    final updated = archive('new', comparison);
    for (final mismatched in [
      FullReplacementArchiveDiffer(
        releaseBaseHash: 'ff' * 32,
        comparisonBaseHash: sha256Hex(comparison),
      ),
      FullReplacementArchiveDiffer(
        releaseBaseHash: sha256Hex(released),
        comparisonBaseHash: 'invalid',
      ),
    ]) {
      await expectLater(
        mismatched.changedFiles(old.path, updated.path),
        throwsFormatException,
      );
    }
  });

  test('requires both embedded wrappers to be baselines', () async {
    final update = _baseline(1, update: true);
    final badComparisonDiffer = FullReplacementArchiveDiffer(
      releaseBaseHash: sha256Hex(released),
      comparisonBaseHash: sha256Hex(update),
    );
    final old = archive('old', released);
    final updated = archive('new', update);
    await expectLater(
      badComparisonDiffer.changedFiles(old.path, updated.path),
      throwsFormatException,
    );
    final badReleaseDiffer = FullReplacementArchiveDiffer(
      releaseBaseHash: sha256Hex(update),
      comparisonBaseHash: sha256Hex(comparison),
    );
    await expectLater(
      badReleaseDiffer.changedFiles(
        updated.path,
        archive('comparison', comparison).path,
      ),
      throwsFormatException,
    );
  });

  test(
    'requires root and host ABI to match across validated baselines',
    () async {
      final old = archive('old', released);
      for (final candidate in [
        _baseline(1, root: 'package:app/other.dart'),
        _baseline(1, host: List.filled(32, 1)),
      ]) {
        final updated = archive('new', candidate);
        final otherDiffer = FullReplacementArchiveDiffer(
          releaseBaseHash: sha256Hex(released),
          comparisonBaseHash: sha256Hex(candidate),
        );
        await expectLater(
          otherDiffer.changedFiles(old.path, updated.path),
          throwsFormatException,
        );
      }
    },
  );

  for (final path in [_policyPath, _basePath]) {
    test('rejects missing $path', () async {
      final old = archive('old', released);
      final updated = archive('new', comparison, omitted: {path});
      await expectLater(
        differ.changedFiles(old.path, updated.path),
        throwsFormatException,
      );
    });

    test('rejects duplicate central directory entries for $path', () async {
      final old = archive('old', released);
      final duplicate = path == _basePath
          ? comparison
          : utf8.encode(jsonEncode(_policy(comparison)));
      final updated = archive(
        'new',
        comparison,
        extra: [MapEntry(path, duplicate)],
      );
      await expectLater(
        differ.changedFiles(old.path, updated.path),
        throwsFormatException,
      );
    });
  }

  test(
    'rejects unmatched policies or baselines in separate bundles',
    () async {
      final old = archive('old', released);
      for (final entry in [
        MapEntry(
          'second/flutter_assets/shorebird.yaml',
          utf8.encode(jsonEncode(_policy(comparison))),
        ),
        MapEntry(
          'second/flutter_assets/shorebird_replacement_base.sbr',
          comparison,
        ),
      ]) {
        final updated = archive('new', comparison, extra: [entry]);
        await expectLater(
          differ.changedFiles(old.path, updated.path),
          throwsFormatException,
        );
      }
    },
  );

  test('validates and normalizes every distinct owned asset bundle', () async {
    const secondPolicy = 'second/flutter_assets/shorebird.yaml';
    const secondBase = 'second/flutter_assets/shorebird_replacement_base.sbr';
    List<MapEntry<String, List<int>>> bundle(
      List<int> bytes, {
      Map<String, Object?> overrides = const {},
    }) => [
      MapEntry(
        secondPolicy,
        utf8.encode(jsonEncode(_policy(bytes)..addAll(overrides))),
      ),
      MapEntry(secondBase, bytes),
      MapEntry(
        'second/flutter_assets/shorebird_native_assets.json',
        _descriptor(),
      ),
    ];
    final old = archive('old', released, extra: bundle(released));
    final updated = archive('new', comparison, extra: bundle(comparison));
    expect(await differ.changedFiles(old.path, updated.path), isEmpty);

    final changed = archive(
      'changed',
      comparison,
      extra: bundle(comparison, overrides: {'app_id': 'another app'}),
    );
    expect((await differ.changedFiles(old.path, changed.path)).changedPaths, {
      secondPolicy,
    });

    final invalid = archive(
      'invalid',
      comparison,
      extra: bundle(
        comparison,
        overrides: {'aot_patch_full_replacement': false},
      ),
    );
    await expectLater(
      differ.changedFiles(old.path, invalid.path),
      throwsFormatException,
    );

    final mismatched = archive(
      'mismatched',
      comparison,
      extra: [
        MapEntry(secondPolicy, utf8.encode(jsonEncode(_policy(comparison)))),
        MapEntry(secondBase, released),
      ],
    );
    await expectLater(
      differ.changedFiles(old.path, mismatched.path),
      throwsFormatException,
    );
  });

  test('retains added and removed validated bundles', () async {
    const policy = 'second/flutter_assets/shorebird.yaml';
    const base = 'second/flutter_assets/shorebird_replacement_base.sbr';
    const descriptor = 'second/flutter_assets/shorebird_native_assets.json';
    final old = archive('old', released);
    final updated = archive(
      'new',
      comparison,
      extra: [
        MapEntry(policy, utf8.encode(jsonEncode(_policy(comparison)))),
        MapEntry(base, comparison),
        MapEntry(descriptor, _descriptor()),
      ],
    );
    final added = await differ.changedFiles(old.path, updated.path);
    expect(added.addedPaths, {policy, base, descriptor});
    expect(added.changedPaths, isEmpty);
    final reverse = FullReplacementArchiveDiffer(
      releaseBaseHash: sha256Hex(comparison),
      comparisonBaseHash: sha256Hex(released),
    );
    final removed = await reverse.changedFiles(updated.path, old.path);
    expect(removed.removedPaths, {policy, base, descriptor});
    expect(removed.changedPaths, isEmpty);
  });

  test('rejects duplicate unowned archive entries too', () async {
    final old = archive('old', released);
    final updated = archive(
      'new',
      comparison,
      extra: [
        MapEntry('Podfile.lock', utf8.encode('ambiguous pods')),
      ],
    );
    await expectLater(
      differ.changedFiles(old.path, updated.path),
      throwsFormatException,
    );
  });

  test('requires policy and baseline to be in the same asset bundle', () async {
    final old = archive('old', released);
    final updated = archive(
      'new',
      comparison,
      omitted: {_basePath},
      extra: [
        MapEntry(
          'other/flutter_assets/shorebird_replacement_base.sbr',
          comparison,
        ),
      ],
    );
    await expectLater(
      differ.changedFiles(old.path, updated.path),
      throwsFormatException,
    );
  });

  test('releases archive streams on success and failed validation', () async {
    final old = archive('old', released);
    final updated = archive('new', comparison);
    await differ.changedFiles(old.path, updated.path);
    updated.deleteSync();
    final invalid = archive('invalid', comparison, omitted: {_basePath});
    await expectLater(
      differ.changedFiles(old.path, invalid.path),
      throwsFormatException,
    );
    invalid.deleteSync();
    old.deleteSync();
  });
}

List<int> _descriptor({String? mappingHash, bool newline = true}) =>
    utf8.encode(
      '${jsonEncode({
        'schema': 1,
        'target': 'ios_arm64',
        'carrier_present': mappingHash != null,
        'mapping_sha256': ?mappingHash,
      })}${newline ? '\n' : ''}',
    );

List<int> _baseline(
  int value, {
  String root = _root,
  List<int>? host,
  bool update = false,
}) {
  final component = [0x33, 0x43, 0x42, 0x44, value];
  return FullReplacementBundle(
    manifest: FullReplacementManifest(
      hostAbi: host ?? List.filled(32, 0),
      baselineDigest: readHexBytes(
        sha256Hex(update ? [1] : component),
        expectedBytes: 32,
        name: 'baseline digest',
      ),
      currentDigest: readHexBytes(
        sha256Hex(component),
        expectedBytes: 32,
        name: 'current digest',
      ),
      rootUri: root,
      baselineUris: [root],
      currentUris: [root],
      removedUris: const [],
    ),
    component: component,
  ).encode();
}

Map<String, Object?> _policy(List<int> baseline) => {
  'app_id': 'example',
  'aot_patch_full_replacement': true,
  'aot_patch_runtime_mode': runtimeModeDartBytecodeInterpreter,
  'aot_patch_replacement_base': 'shorebird_replacement_base.sbr',
  'aot_patch_host_abi': FullReplacementBundle.decode(
    baseline,
  ).manifest.hostAbiHex,
  'aot_patch_base_snapshot_hash': sha256Hex(baseline),
  'patch_public_key': 'pinned key',
  'patch_verification': 'strict',
};

File _writeArchive(
  Directory directory,
  String name,
  List<MapEntry<String, List<int>>> entries,
) {
  final archive = Archive();
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    // Assign real names after insertion so Archive does not coalesce duplicate
    // names. The encoder must preserve those duplicate central directory rows.
    final file = ArchiveFile('entry-$i', entry.value.length, entry.value);
    archive.add(file);
    file.name = entry.key;
  }
  return File(p.join(directory.path, '$name.zip'))
    ..writeAsBytesSync(ZipEncoder().encode(archive));
}
