import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/config/shorebird_yaml.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:yaml/yaml.dart';

/// The security profiles of contract v1 (docs/HARDENING_CONTRACTS.md §2).
///
/// A profile is chosen once, at native-release time, and every patch of that
/// release inherits it.
enum SecurityProfile {
  /// Today's behavior, unchanged. The default.
  legacy,

  /// Opt-in: signed patches, strict verification, required response
  /// verification and an HTTPS update origin, enforced by a toolchain that was
  /// built hardened.
  hardened;

  /// A profile name contract v1 reserves for a later version and rejects.
  static const reservedDiversified = 'hardened-diversified';

  /// The profile named [value], or null when [value] is not a v1 profile.
  static SecurityProfile? tryParse(String value) => switch (value) {
    'legacy' => SecurityProfile.legacy,
    'hardened' => SecurityProfile.hardened,
    _ => null,
  };
}

/// The environment variable that tells `flutter build` the release's profile.
const securityProfileEnvironmentVariable = 'SHOREBIRD_SECURITY_PROFILE';

/// The environment variable that tells `flutter build` the toolchain ID.
const toolchainIdEnvironmentVariable = 'SHOREBIRD_TOOLCHAIN_ID';

/// The `shorebird.yaml` keys only `flutter build` may write (into the bundled
/// copy). A checked-in `shorebird.yaml` must not contain them.
const reservedSecurityYamlKeys = {
  'security_profile',
  'security_contract_version',
  'toolchain_id',
  'security_development_exceptions',
  'shorebird_build_manifest',
};

/// The path of the PKCS#8 PEM Ed25519 key that signs the build manifest of a
/// hardened build (hardening P3, docs/HARDENING_CONTRACTS.md §9 and §10). Its
/// public key must be a `build-manifest` key that the release-trust bundle
/// delegates under the release root compiled into the hardened engine.
/// `flutter build` reads it directly.
const buildManifestSigningKeyEnvironmentVariable =
    'SHOREBIRD_BUILD_MANIFEST_SIGNING_KEY';

/// An external signer executable (KMS/HSM adapter) used instead of
/// [buildManifestSigningKeyEnvironmentVariable] (contract v2 §10).
const buildManifestSignerEnvironmentVariable =
    'SHOREBIRD_BUILD_MANIFEST_SIGNER';

/// The `sha256:` key ID the external signer holds.
const buildManifestSignerKeyIdEnvironmentVariable =
    'SHOREBIRD_BUILD_MANIFEST_SIGNER_KEY_ID';

/// The path of the `release-trust` bundle (root chain and delegations) a
/// hardened build embeds in its build manifest.
const releaseTrustEnvironmentVariable = 'SHOREBIRD_RELEASE_TRUST';

/// The release-root pin the toolchain's engine was compiled with, passed to
/// `flutter build` from `toolchain_security.json`.
const releaseRootEnvironmentVariable = 'SHOREBIRD_RELEASE_ROOT';

/// The compiled delegations version floor, passed to `flutter build`.
const releaseMinDelegationsVersionEnvironmentVariable =
    'SHOREBIRD_RELEASE_MIN_DELEGATIONS_VERSION';

/// Where `flutter build` writes the hardened release record (one file per
/// build manifest) for `shorebird release` to store with the release.
const buildManifestRecordDirEnvironmentVariable =
    'SHOREBIRD_BUILD_MANIFEST_RECORD_DIR';

/// Comma-separated SHA-256 digests of the Android signer certificate(s) a
/// hardened Android install must carry (optional; enables repack detection).
const androidSigningCertEnvironmentVariable =
    'SHOREBIRD_ANDROID_SIGNING_CERT_SHA256';

/// Comma-separated Apple team identifiers a hardened macOS app must be signed
/// by (optional; enables repack detection).
const appleTeamIdsEnvironmentVariable = 'SHOREBIRD_APPLE_TEAM_IDS';

const _pkcs8Ed25519Prefix = [
  0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, //
  0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
];

/// The problems that keep a hardened build of [platform] (a release platform
/// name such as `android` or `macos`) from signing its build manifest with
/// [environment], as complete sentences. Empty when the build can sign.
///
/// `flutter build` enforces the same rules; checking here fails a release or
/// patch before any build starts.
List<String> hardenedBuildManifestProblems(
  Map<String, String> environment, {
  required String platform,
}) {
  final problems = <String>[];
  final trustPath = environment[releaseTrustEnvironmentVariable] ?? '';
  if (trustPath.isEmpty) {
    problems.add(
      'Set $releaseTrustEnvironmentVariable to the release-trust bundle '
      '(scripts/release_trust.py bundle) that delegates your build-manifest '
      'key under the release root this toolchain was built with.',
    );
  } else {
    final trustError = _releaseTrustShapeError(trustPath);
    if (trustError != null) problems.add(trustError);
  }
  final keyPath = environment[buildManifestSigningKeyEnvironmentVariable] ?? '';
  final signer = environment[buildManifestSignerEnvironmentVariable] ?? '';
  if (keyPath.isNotEmpty && signer.isNotEmpty) {
    problems.add(
      'Set only one build-manifest signer: '
      '$buildManifestSigningKeyEnvironmentVariable (a key file) or '
      '$buildManifestSignerEnvironmentVariable (an external KMS/HSM signer).',
    );
  } else if (signer.isNotEmpty) {
    final keyId =
        environment[buildManifestSignerKeyIdEnvironmentVariable] ?? '';
    if (!RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(keyId)) {
      problems.add(
        '$buildManifestSignerEnvironmentVariable needs '
        '$buildManifestSignerKeyIdEnvironmentVariable, the sha256: key ID '
        'of the key the signer holds.',
      );
    }
  } else if (keyPath.isEmpty) {
    problems.add(
      'Set $buildManifestSigningKeyEnvironmentVariable to the Ed25519 '
      'build-manifest signing key (PKCS#8 PEM), or '
      '$buildManifestSignerEnvironmentVariable to an external signer, for a '
      'build-manifest key the release-trust bundle delegates.',
    );
  } else {
    final file = File(keyPath);
    String? pem;
    try {
      pem = file.readAsStringSync();
    } on FileSystemException {
      problems.add(
        '$buildManifestSigningKeyEnvironmentVariable names $keyPath, which '
        'cannot be read.',
      );
    }
    if (pem != null && !_isPkcs8Ed25519Pem(pem)) {
      problems.add(
        '$buildManifestSigningKeyEnvironmentVariable must be a PKCS#8 PEM '
        'Ed25519 private key (openssl genpkey -algorithm ed25519).',
      );
    }
  }
  final certs = _list(environment[androidSigningCertEnvironmentVariable]);
  if (certs.isNotEmpty && platform != 'android') {
    problems.add(
      '$androidSigningCertEnvironmentVariable applies only to Android '
      'releases.',
    );
  }
  for (final cert in certs) {
    if (!RegExp(
      r'^[0-9a-f]{64}$',
    ).hasMatch(cert.replaceAll(':', '').toLowerCase())) {
      problems.add(
        '$androidSigningCertEnvironmentVariable entry $cert is not a SHA-256 '
        'certificate digest.',
      );
    }
  }
  final teams = _list(environment[appleTeamIdsEnvironmentVariable]);
  if (teams.isNotEmpty && platform != 'macos') {
    problems.add(
      '$appleTeamIdsEnvironmentVariable applies only to macOS releases (iOS '
      'cannot verify a team identifier at run time).',
    );
  }
  for (final team in teams) {
    if (!RegExp(r'^[A-Z0-9]{10}$').hasMatch(team)) {
      problems.add(
        '$appleTeamIdsEnvironmentVariable entry $team is not an Apple team '
        'identifier.',
      );
    }
  }
  return problems;
}

/// Why the file at [path] is not a contract v2 `release-trust` bundle, or
/// null. `flutter build` verifies its signatures against the compiled root.
String? _releaseTrustShapeError(String path) {
  final Object? decoded;
  try {
    decoded = jsonDecode(File(path).readAsStringSync());
  } on FileSystemException {
    return '$releaseTrustEnvironmentVariable names $path, which cannot be '
        'read.';
  } on FormatException {
    return '$releaseTrustEnvironmentVariable names $path, which is not JSON.';
  }
  if (decoded is! Map<String, Object?> ||
      decoded['schema'] != 'open-shorebird.release-trust' ||
      decoded['contract_version'] != 2) {
    return '$releaseTrustEnvironmentVariable names $path, which is not a '
        'contract v2 open-shorebird.release-trust bundle.';
  }
  return null;
}

List<String> _list(String? value) => [
  for (final item in (value ?? '').split(','))
    if (item.trim().isNotEmpty) item.trim(),
];

bool _isPkcs8Ed25519Pem(String pem) {
  final match = RegExp(
    r'^-----BEGIN PRIVATE KEY-----\s+([A-Za-z0-9+/=\s]+?)\s*-----END PRIVATE KEY-----$',
  ).firstMatch(pem.trim());
  if (match == null) return false;
  final List<int> der;
  try {
    der = base64.decode(match.group(1)!.replaceAll(RegExp(r'\s'), ''));
  } on FormatException {
    return false;
  }
  if (der.length != _pkcs8Ed25519Prefix.length + 32) return false;
  for (var i = 0; i < _pkcs8Ed25519Prefix.length; i++) {
    if (der[i] != _pkcs8Ed25519Prefix[i]) return false;
  }
  return true;
}

final _toolchainIdPattern = RegExp(r'^sha256:[0-9a-f]{64}$');

/// Whether [value] is a well-formed toolchain ID: `sha256:` followed by 64
/// lowercase hex digits.
bool isWellFormedToolchainId(String value) =>
    _toolchainIdPattern.hasMatch(value);

/// Thrown when the toolchain security file exists but cannot be trusted.
class ToolchainSecurityException implements Exception {
  /// Creates a [ToolchainSecurityException] with a complete-sentence [message].
  const ToolchainSecurityException(this.message);

  /// What is wrong with the file.
  final String message;

  @override
  String toString() => message;
}

/// {@template toolchain_security}
/// The security floor the installed Shorebird toolchain was built with, read
/// from `<shorebird root>/bin/internal/toolchain_security.json`.
/// {@endtemplate}
class ToolchainSecurity {
  /// {@macro toolchain_security}
  const ToolchainSecurity({
    required this.profile,
    required this.toolchainId,
    required this.developmentExceptions,
    this.releaseRoot,
    this.minDelegationsVersion = 1,
  });

  /// Reads the floor of the Shorebird install at [shorebirdRoot].
  ///
  /// A missing file means a legacy toolchain. Any other problem throws a
  /// [ToolchainSecurityException]: a floor that cannot be read is never
  /// treated as legacy.
  factory ToolchainSecurity.load(Directory shorebirdRoot) {
    final file = fileIn(shorebirdRoot);
    if (!file.existsSync()) return legacyToolchain;
    final String source;
    try {
      source = file.readAsStringSync();
    } on FileSystemException catch (error) {
      throw ToolchainSecurityException(
        'Could not read ${file.path}: ${error.message}.',
      );
    }
    return ToolchainSecurity.parse(source, path: file.path);
  }

  /// Parses the contents of a toolchain security file. [path] names the file
  /// in error messages.
  factory ToolchainSecurity.parse(String source, {String path = fileName}) {
    Never fail(String reason) =>
        throw ToolchainSecurityException('$path is invalid: $reason');

    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      fail('not valid JSON (${error.message}).');
    }
    if (decoded is! Map<String, Object?>) fail('expected a JSON object.');

    final version = decoded['contract_version'];
    if (version is! int || !supportedContractVersions.contains(version)) {
      fail(
        'unsupported contract_version $version; this Shorebird CLI '
        'understands ${supportedContractVersions.join(' and ')}.',
      );
    }
    final keys = version == 1 ? _keys : _keysV2;
    final unknown = decoded.keys.toSet().difference(keys);
    if (unknown.isNotEmpty) fail('unknown keys ${unknown.join(', ')}.');
    final missing = keys.difference(decoded.keys.toSet());
    if (missing.isNotEmpty) fail('missing keys ${missing.join(', ')}.');

    if (decoded['schema'] != schema) fail('schema must be "$schema".');

    final profileValue = decoded['security_profile'];
    final profile = profileValue is String
        ? SecurityProfile.tryParse(profileValue)
        : null;
    if (profile == null) {
      fail(
        'security_profile must be "legacy" or "hardened", '
        'not ${jsonEncode(profileValue)}.',
      );
    }

    final toolchainId = decoded['toolchain_id'];
    if (toolchainId != null &&
        (toolchainId is! String || !isWellFormedToolchainId(toolchainId))) {
      fail(
        'toolchain_id must be "sha256:" followed by 64 lowercase hex '
        'digits, not ${jsonEncode(toolchainId)}.',
      );
    }
    if (profile == SecurityProfile.hardened && toolchainId == null) {
      fail('a hardened toolchain requires a toolchain_id.');
    }

    final developmentExceptions = decoded['development_exceptions'];
    if (developmentExceptions is! bool) {
      fail('development_exceptions must be true or false.');
    }

    String? releaseRoot;
    var minDelegationsVersion = 1;
    if (version == 2) {
      final root = decoded['release_root'];
      final minimum = decoded['min_delegations_version'];
      if (root != null &&
          (root is! String ||
              !RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(root))) {
        fail('release_root must be the base64 release-root payload or null.');
      }
      if (minimum is! int || minimum < 1) {
        fail('min_delegations_version must be a positive integer.');
      }
      releaseRoot = root as String?;
      minDelegationsVersion = minimum;
    }
    if (profile == SecurityProfile.hardened) {
      // Contract v2 (P4): the build manifest chains to a compiled release
      // root. A v1 hardened engine expects a bare manifest key instead.
      if (version != 2) {
        fail(
          'a hardened toolchain needs contract_version 2 (release root); '
          'rebuild it with shorebird_release_root.',
        );
      }
      if (releaseRoot == null) {
        fail('a hardened toolchain needs a release_root.');
      }
    } else if (releaseRoot != null || minDelegationsVersion != 1) {
      fail('release_root and min_delegations_version are hardened-only.');
    }

    return ToolchainSecurity(
      profile: profile,
      toolchainId: toolchainId as String?,
      developmentExceptions: developmentExceptions,
      releaseRoot: releaseRoot,
      minDelegationsVersion: minDelegationsVersion,
    );
  }

  /// The floor of a toolchain without a `toolchain_security.json`.
  static const legacyToolchain = ToolchainSecurity(
    profile: SecurityProfile.legacy,
    toolchainId: null,
    developmentExceptions: false,
  );

  /// The file name, under `<shorebird root>/bin/internal`.
  static const fileName = 'toolchain_security.json';

  /// The required `schema` value.
  static const schema = 'open-shorebird.toolchain-security';

  /// The contract version a hardened toolchain file must declare.
  static const contractVersion = 2;

  /// The versions this CLI reads: 1 (legacy only) and 2.
  static const supportedContractVersions = [1, 2];

  static const _keys = {
    'schema',
    'contract_version',
    'security_profile',
    'toolchain_id',
    'development_exceptions',
  };

  static const _keysV2 = {
    ..._keys,
    'release_root',
    'min_delegations_version',
  };

  /// The toolchain security file of the Shorebird install at [shorebirdRoot].
  static File fileIn(Directory shorebirdRoot) =>
      File(p.join(shorebirdRoot.path, 'bin', 'internal', fileName));

  /// The profile the toolchain's engine and updater were compiled with.
  final SecurityProfile profile;

  /// The toolchain's build identity. Always set for [SecurityProfile.hardened].
  final String? toolchainId;

  /// Whether this is a visibly development toolchain. Production packaging
  /// (`shorebird release`) refuses such toolchains.
  final bool developmentExceptions;

  /// The release-root pin compiled into the hardened engine (base64
  /// `release-root` payload). Null for legacy.
  final String? releaseRoot;

  /// The compiled delegations version floor.
  final int minDelegationsVersion;

  /// The variables passed to `flutter build` so it writes the bundled
  /// security declaration. Empty for [SecurityProfile.legacy], so legacy
  /// builds see exactly the environment they always did.
  ///
  /// `SHOREBIRD_SECURITY_DEVELOPMENT_EXCEPTIONS` is never passed.
  Map<String, String> get buildEnvironment => switch (profile) {
    SecurityProfile.legacy => const {},
    SecurityProfile.hardened => {
      securityProfileEnvironmentVariable: SecurityProfile.hardened.name,
      toolchainIdEnvironmentVariable: toolchainId!,
      releaseRootEnvironmentVariable: releaseRoot!,
      releaseMinDelegationsVersionEnvironmentVariable: '$minDelegationsVersion',
    },
  };
}

/// A reference to the installed toolchain's [ToolchainSecurity].
///
/// Reading it throws a [ToolchainSecurityException] when the toolchain
/// security file is present but invalid.
final toolchainSecurityRef = create(
  () => ToolchainSecurity.load(shorebirdEnv.shorebirdRoot),
);

/// The [ToolchainSecurity] available in the current zone.
ToolchainSecurity get toolchainSecurity => read(toolchainSecurityRef);

/// The [reservedSecurityYamlKeys] that the top level of the `shorebird.yaml`
/// [source] contains. Returns an empty list when [source] is not a YAML map;
/// the regular parser reports that.
List<String> reservedSecurityKeysIn(String source) {
  final Object? document;
  try {
    document = loadYaml(source);
  } on YamlException {
    return const [];
  }
  if (document is! Map) return const [];
  return [
    for (final key in document.keys)
      if (key is String && reservedSecurityYamlKeys.contains(key)) key,
  ];
}

/// Why a hardened toolchain refuses the legacy all-in-one artifact mirror.
const hardenedLegacyMirrorRefusal =
    'This Shorebird toolchain is hardened: its artifacts resolve only through '
    'the signed artifact catalog (split origin mode). The legacy all-in-one '
    'mirror (SHOREBIRD_ORIGIN_MODE set to legacy-mirror, '
    'SHOREBIRD_DOWNLOAD_URL or SHOREBIRD_FLUTTER_STORAGE_BASE_URL) routes '
    'them through an unverified proxy instead. Unset those; use '
    'FLUTTER_STORAGE_BASE_URL for an official mirror and '
    'SHOREBIRD_ARTIFACT_BASE_URL for the custom artifact store.';

/// The problems that keep [yaml] from configuring a hardened release, as
/// complete sentences. Empty when [yaml] meets the hardened floor.
///
/// `base_url` must be explicit HTTPS with a host and no user info. There is no
/// loopback HTTP exception: that is for development toolchains only, and
/// releases are never built with those.
List<String> hardenedShorebirdYamlProblems(ShorebirdYaml? yaml) {
  final problems = <String>[];
  final baseUrl = yaml?.baseUrl;
  if (baseUrl == null || baseUrl.trim().isEmpty) {
    problems.add(
      'shorebird.yaml must set base_url to the https:// URL of your '
      'update server.',
    );
  } else {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || uri.scheme != 'https') {
      problems.add('base_url in shorebird.yaml must use https, not $baseUrl.');
    } else if (uri.host.isEmpty) {
      problems.add('base_url in shorebird.yaml must name a host.');
    } else if (uri.userInfo.isNotEmpty) {
      problems.add(
        'base_url in shorebird.yaml must not contain user info (user@).',
      );
    }
  }
  if (yaml?.patchVerification case final verification?
      when verification != PatchVerification.strict) {
    problems.add(
      'patch_verification in shorebird.yaml must be strict (or unset), not '
      'install_only.',
    );
  }
  if (yaml?.patchResponseVerification case final verification?
      when verification != PatchResponseVerification.required) {
    problems.add(
      'patch_response_verification in shorebird.yaml must be required (or '
      'unset), not optional.',
    );
  }
  return problems;
}

/// Thrown when the release record a hardened build wrote is missing or
/// inconsistent.
class ReleaseRecordException implements Exception {
  /// Creates a [ReleaseRecordException] with a complete-sentence [message].
  const ReleaseRecordException(this.message);

  /// What is wrong.
  final String message;

  @override
  String toString() => message;
}

/// Merges the `release-record.v2` files `flutter build` wrote into
/// [directory] (one per distinct build manifest) into the one record stored
/// with the release (docs/HARDENING_CONTRACTS.md §10). Every file must agree
/// on the toolchain and the release trust; the build manifests are listed
/// once each, by digest.
Map<String, Object?> readReleaseRecord(Directory directory) {
  final files = directory.existsSync()
      ? (directory
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.json'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path)))
      : <File>[];
  if (files.isEmpty) {
    throw ReleaseRecordException(
      'The hardened build wrote no release record to ${directory.path}; '
      'the Flutter toolchain may predate contract v2.',
    );
  }
  Map<String, Object?>? merged;
  final manifests = <String, Object?>{};
  for (final file in files) {
    final Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } on FormatException {
      throw ReleaseRecordException('${file.path} is not JSON.');
    }
    if (decoded is! Map<String, Object?> ||
        decoded['schema'] != 'open-shorebird.release-record' ||
        decoded['contract_version'] != 2 ||
        decoded['build_manifests'] is! List<Object?>) {
      throw ReleaseRecordException(
        '${file.path} is not a contract v2 release record.',
      );
    }
    final shared = Map<String, Object?>.of(decoded)..remove('build_manifests');
    if (merged == null) {
      merged = shared;
    } else if (jsonEncode(_sorted(merged)) != jsonEncode(_sorted(shared))) {
      throw ReleaseRecordException(
        'The release records in ${directory.path} disagree on the toolchain '
        'or the release trust; every build of a release must be signed '
        'under the same delegations.',
      );
    }
    for (final manifest in decoded['build_manifests']! as List<Object?>) {
      if (manifest is! Map<String, Object?> ||
          manifest['manifest_sha256'] is! String) {
        throw ReleaseRecordException('${file.path} has a malformed entry.');
      }
      manifests[manifest['manifest_sha256']! as String] = manifest;
    }
  }
  final digests = manifests.keys.toList()..sort();
  return {
    ...merged!,
    'build_manifests': [for (final digest in digests) manifests[digest]],
  };
}

Object? _sorted(Object? value) => switch (value) {
  final Map<String, Object?> map => {
    for (final key in map.keys.toList()..sort()) key: _sorted(map[key]),
  },
  final List<Object?> list => [for (final item in list) _sorted(item)],
  _ => value,
};
