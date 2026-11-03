import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// `aot_patch_runtime_mode` value of the iOS linked AOT profile (`aot-link`).
///
/// A release is a normal TFA AOT build whose gen_snapshot also writes a link
/// sidecar. A patch is a full optimized AOT build compiled against that
/// sidecar; unchanged code runs from the release's native instructions and
/// the rest in the runtime's simulator. See docs/ios-linker/COMPILER_LINKER.md.
const runtimeModeIosAotLink = 'ios-aot-link';

/// Name of the profile in release scopes and messages.
const profileAotLink = 'aot-link';

/// The release supplement of an `aot-link` release.
///
/// The directory holds the files below plus the manifest. The manifest lists
/// every file with its SHA-256 and size, the compiler identity lines of the
/// sidecar and the SHA-256 of the release text image (the value the patch's
/// vmcode header must carry). Nothing in the directory is trusted until
/// [AotLinkSupplement.verify] has checked it against the manifest, and the
/// archive itself is signed by the existing supplement upload.
class AotLinkSupplement {
  const AotLinkSupplement._({
    required this.files,
    required this.snapshotHash,
    required this.features,
    required this.textImageSize,
    required this.releaseTextSha256,
    required this.ddMaxBytes,
    required this.ddPackages,
    this.releaseId,
    this.appBuildId,
  });

  /// The manifest format version.
  static const version = 1;

  /// File name of the manifest in the supplement directory.
  static const manifestFileName = 'aot_link_supplement.json';

  /// The release link sidecar (`--print_link_info_to`).
  static const linkFileName = 'App.link';

  /// The DD target list; present only when DD is enabled.
  static const ddFileName = 'App.dd';

  /// The release kernel, input of the patch's frontend-free gen_snapshot runs.
  static const kernelFileName = 'app.dill';

  /// The release `App.framework/App` as built, before App Store processing.
  static const releaseBinaryFileName = 'App.macho';

  static const _required = {
    linkFileName,
    kernelFileName,
    releaseBinaryFileName,
  };
  static const _allowed = {..._required, ddFileName};

  /// SHA-256 and size of each file by name.
  final Map<String, ({String sha256, int size})> files;

  /// `id snapshot_hash` of the sidecar: the compiler that built the release.
  final String snapshotHash;

  /// `id features` of the sidecar.
  final String features;

  /// `meta text_image_size` of the sidecar.
  final int textImageSize;

  /// SHA-256 of the release `_kDartSnapshotText` image.
  final String releaseTextSha256;

  /// The DD threshold the release used (0 = DD off).
  final int ddMaxBytes;

  /// The packages DD targets were restricted to.
  final List<String> ddPackages;

  /// The server release id, stamped at upload; not part of any hash.
  final int? releaseId;

  /// The release version, stamped at upload.
  final String? appBuildId;

  /// Whether the release uses DD.
  bool get usesDd => files.containsKey(ddFileName);

  /// Describes the files already in [directory] and writes the manifest.
  ///
  /// [releaseTextSha256] and [textImageSize] come from the release binary
  /// (`ios_linker info`); they must agree with the sidecar's own
  /// `text_image_size`. Throws [AotLinkSupplementException] on missing or
  /// unexpected files.
  // ignore: prefer_constructors_over_static_methods
  static AotLinkSupplement write(
    Directory directory, {
    required String releaseTextSha256,
    required int textImageSize,
    int ddMaxBytes = 0,
    List<String> ddPackages = const [],
  }) {
    final names = _listFiles(directory)..remove(manifestFileName);
    for (final name in names) {
      if (!_allowed.contains(name)) {
        throw AotLinkSupplementException('unexpected file $name');
      }
    }
    for (final name in _required) {
      if (!names.contains(name)) {
        throw AotLinkSupplementException('missing $name');
      }
    }
    final usesDd = names.contains(ddFileName);
    if (usesDd != (ddMaxBytes > 0)) {
      throw AotLinkSupplementException(
        usesDd
            ? 'App.dd exists but DD is not enabled'
            : 'DD is enabled but there is no App.dd',
      );
    }
    final identity = readSidecarIdentity(
      File(p.join(directory.path, linkFileName)),
    );
    if (identity.textImageSize != textImageSize) {
      throw AotLinkSupplementException(
        'sidecar text_image_size ${identity.textImageSize} differs from the '
        'release binary ($textImageSize)',
      );
    }
    final supplement = AotLinkSupplement._(
      files: {
        for (final name in names.toList()..sort())
          name: _describe(File(p.join(directory.path, name))),
      },
      snapshotHash: identity.snapshotHash,
      features: identity.features,
      textImageSize: textImageSize,
      releaseTextSha256: releaseTextSha256,
      ddMaxBytes: ddMaxBytes,
      ddPackages: ddPackages,
    );
    return supplement.._save(directory);
  }

  /// Stamps the release id and version into the manifest in [directory].
  static void stamp(
    Directory directory, {
    required int releaseId,
    String? appBuildId,
  }) {
    final file = File(p.join(directory.path, manifestFileName));
    final json = (jsonDecode(file.readAsStringSync()) as Map)
        .cast<String, Object?>();
    json['release_id'] = releaseId;
    json['app_build_id'] = appBuildId;
    file.writeAsStringSync(jsonEncode(json));
  }

  /// Reads the manifest in [directory] and verifies everything against it:
  /// the file set, every size and SHA-256, and the compiler identity of the
  /// sidecar. Throws [AotLinkSupplementException] on any mismatch.
  static AotLinkSupplement verify(Directory directory) {
    final manifest = File(p.join(directory.path, manifestFileName));
    if (!manifest.existsSync()) {
      throw const AotLinkSupplementException(
        'the release supplement has no $manifestFileName; it was not created '
        'with the aot-link profile',
      );
    }
    final Map<String, Object?> json;
    try {
      json = (jsonDecode(manifest.readAsStringSync()) as Map)
          .cast<String, Object?>();
    } on Object {
      throw const AotLinkSupplementException(
        '$manifestFileName is not valid JSON',
      );
    }
    if (json['version'] != version || json['profile'] != profileAotLink) {
      throw AotLinkSupplementException(
        'unsupported supplement (version ${json['version']}, '
        'profile ${json['profile']})',
      );
    }
    final listed =
        (json['files'] as Map?)?.cast<String, Object?>() ??
        const <String, Object?>{};
    final files = <String, ({String sha256, int size})>{};
    for (final entry in listed.entries) {
      final value = (entry.value as Map).cast<String, Object?>();
      files[entry.key] = (
        sha256: value['sha256']! as String,
        size: value['size']! as int,
      );
    }
    for (final name in _required) {
      if (!files.containsKey(name)) {
        throw AotLinkSupplementException('the manifest does not list $name');
      }
    }
    final onDisk = _listFiles(directory)..remove(manifestFileName);
    if (!onDisk.containsAll(files.keys) ||
        !files.keys.toSet().containsAll(onDisk)) {
      final extra = onDisk.difference(files.keys.toSet());
      final missing = files.keys.toSet().difference(onDisk);
      throw AotLinkSupplementException(
        'the supplement files differ from the manifest '
        '(missing: ${missing.join(', ')}; unlisted: ${extra.join(', ')})',
      );
    }
    for (final entry in files.entries) {
      if (!_allowed.contains(entry.key)) {
        throw AotLinkSupplementException('unexpected file ${entry.key}');
      }
      final actual = _describe(File(p.join(directory.path, entry.key)));
      if (actual.size != entry.value.size ||
          actual.sha256 != entry.value.sha256) {
        throw AotLinkSupplementException(
          '${entry.key} does not match its recorded SHA-256 '
          '(recorded ${entry.value.sha256}, actual ${actual.sha256})',
        );
      }
    }
    final identity = readSidecarIdentity(
      File(p.join(directory.path, linkFileName)),
    );
    final supplement = AotLinkSupplement._(
      files: files,
      snapshotHash: json['snapshot_hash']! as String,
      features: json['features']! as String,
      textImageSize: json['text_image_size']! as int,
      releaseTextSha256: json['release_text_sha256']! as String,
      ddMaxBytes: (json['dd'] as Map?)?['max_bytes'] as int? ?? 0,
      ddPackages:
          ((json['dd'] as Map?)?['packages'] as List?)?.cast<String>() ??
          const [],
      releaseId: json['release_id'] as int?,
      appBuildId: json['app_build_id'] as String?,
    );
    if (identity.snapshotHash != supplement.snapshotHash ||
        identity.features != supplement.features ||
        identity.textImageSize != supplement.textImageSize) {
      throw const AotLinkSupplementException(
        'the sidecar identity lines differ from the manifest',
      );
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(supplement.releaseTextSha256)) {
      throw const AotLinkSupplementException(
        'release_text_sha256 is malformed',
      );
    }
    if (supplement.usesDd != (supplement.ddMaxBytes > 0)) {
      throw const AotLinkSupplementException(
        'the DD record and App.dd disagree',
      );
    }
    return supplement;
  }

  void _save(Directory directory) {
    File(p.join(directory.path, manifestFileName)).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'version': version,
        'profile': profileAotLink,
        'runtime_mode': runtimeModeIosAotLink,
        'snapshot_hash': snapshotHash,
        'features': features,
        'text_image_size': textImageSize,
        'release_text_sha256': releaseTextSha256,
        'dd': {'max_bytes': ddMaxBytes, 'packages': ddPackages},
        'files': {
          for (final entry in files.entries)
            entry.key: {'sha256': entry.value.sha256, 'size': entry.value.size},
        },
        'release_id': ?releaseId,
        'app_build_id': ?appBuildId,
      }),
    );
  }

  static Set<String> _listFiles(Directory directory) {
    final names = <String>{};
    for (final entity in directory.listSync(followLinks: false)) {
      if (entity is! File) {
        throw AotLinkSupplementException(
          'unexpected entry ${p.basename(entity.path)}',
        );
      }
      names.add(p.basename(entity.path));
    }
    return names;
  }

  static ({String sha256, int size}) _describe(File file) {
    final bytes = file.readAsBytesSync();
    return (sha256: sha256.convert(bytes).toString(), size: bytes.length);
  }
}

/// The identity lines at the top of a link sidecar.
typedef SidecarIdentity = ({
  String snapshotHash,
  String features,
  int textImageSize,
});

/// Reads the compiler identity (`id` lines) and `meta text_image_size` from
/// the head of [sidecar] without parsing the (multi-megabyte) rest.
SidecarIdentity readSidecarIdentity(File sidecar) {
  final raf = sidecar.openSync();
  final String head;
  try {
    head = utf8.decode(raf.readSync(65536), allowMalformed: true);
  } finally {
    raf.closeSync();
  }
  final lines = head.split('\n');
  if (lines.isEmpty || !lines.first.startsWith('#osb-link-info ')) {
    throw const AotLinkSupplementException('App.link is not a link sidecar');
  }
  String? snapshotHash;
  String? features;
  int? textImageSize;
  for (final line in lines.skip(1)) {
    final cells = line.split('\t');
    if (cells[0] == 'id' && cells.length >= 3) {
      if (cells[1] == 'snapshot_hash') snapshotHash = cells[2];
      if (cells[1] == 'features') features = cells[2];
    } else if (cells[0] == 'meta' &&
        cells.length >= 3 &&
        cells[1] == 'text_image_size') {
      textImageSize = int.tryParse(cells[2]);
    } else if (cells[0] != 'meta' && cells[0] != 'id' && cells[0].isNotEmpty) {
      break;
    }
  }
  if (snapshotHash == null || features == null || textImageSize == null) {
    throw const AotLinkSupplementException(
      'App.link has no compiler identity or text_image_size',
    );
  }
  return (
    snapshotHash: snapshotHash,
    features: features,
    textImageSize: textImageSize,
  );
}

/// A supplement that cannot be used.
class AotLinkSupplementException implements Exception {
  /// Creates the exception with [message].
  const AotLinkSupplementException(this.message);

  /// What is wrong.
  final String message;

  @override
  String toString() => 'Invalid aot-link release supplement: $message';
}

/// Link percentage policy of an `aot-link` patch.
class AotLinkPolicy {
  /// Creates a policy; both thresholds are percentages in [0, 100].
  const AotLinkPolicy({
    this.warnBelow = defaultWarnBelow,
    this.failBelow = defaultFailBelow,
  }) : assert(
         failBelow <= warnBelow,
         'the failure threshold must not exceed the warning one',
       );

  /// Upstream's default: warn below 90%.
  static const defaultWarnBelow = 90;

  /// Upstream's default: fail below 20%.
  static const defaultFailBelow = 20;

  /// Warn when less of the patch's code links.
  final num warnBelow;

  /// Refuse the patch when less of its code links (`--min-link-percent`).
  final num failBelow;
}

/// `ios_linker` exit codes (COMPILER_LINKER.md section 5 and 8).
enum IosLinkerFailure {
  /// `check` found an inconsistency, or texts differ.
  checkFailed(1),

  /// A VM stub does not link: release and patch use different toolchains.
  unlinkedStub(2),

  /// The link percentage is below `--min-link-percent`.
  belowMinimum(3),

  /// Sidecar version, compiler identity or format mismatch.
  sidecarMismatch(4),

  /// The patch needs more runtime gates (simulator entry points) than the
  /// engine provides; no vmcode is written.
  gateBudget(5),

  /// Bad usage.
  usage(64);

  const IosLinkerFailure(this.exitCode);

  /// The process exit code.
  final int exitCode;

  /// The failure for [code], or null for other codes.
  static IosLinkerFailure? fromExitCode(int code) {
    for (final value in values) {
      if (value.exitCode == code) return value;
    }
    return null;
  }

  /// A message for the user; [detail] is the tool's own message.
  String describe({num? failBelow, String detail = ''}) {
    final suffix = detail.trim().isEmpty ? '' : '\n${detail.trim()}';
    return switch (this) {
      checkFailed =>
        'The linked patch failed independent verification. This is a bug in '
            'the linker or a corrupt build; the patch was not published.$suffix',
      unlinkedStub =>
        'The patch and the release were not built by the same Flutter engine: '
            'some VM stubs do not match. Patch with the Flutter version the '
            'release was built with.$suffix',
      belowMinimum =>
        "Too little of the patch could reuse the release's native code "
            '(below ${failBelow ?? AotLinkPolicy.defaultFailBelow}%). The app '
            'would run most of it in the simulator, far slower. Lower '
            '--min-link-percentage only if you accept that.$suffix',
      sidecarMismatch =>
        'The release link data does not match this patch build: the release '
            'was built by a different gen_snapshot (or an old sidecar format). '
            'Patch with the Flutter version the release was built with.$suffix',
      gateBudget =>
        'Too much of the patch would run in the simulator: it needs more '
            'runtime gates than the engine supports. Reduce the change, or '
            'create the release with DD (--aot-link-dd-max-bytes) so a small '
            'change does not unlink its callers.$suffix',
      usage => 'ios_linker was invoked incorrectly (a Shorebird bug).$suffix',
    };
  }
}
