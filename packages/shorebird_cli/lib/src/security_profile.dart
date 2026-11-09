import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/config/shorebird_yaml.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:yaml/yaml.dart';

/// The security profiles (docs/HARDENING_CONTRACTS.md §2 and §11).
///
/// A profile is chosen once, at native-release time, and every patch of that
/// release inherits it.
enum SecurityProfile {
  /// Today's behavior, unchanged. The default.
  legacy('legacy'),

  /// Opt-in: signed patches, strict verification, required response
  /// verification and an HTTPS update origin, enforced by a toolchain that was
  /// built hardened.
  hardened('hardened'),

  /// Contract v3 (P5): [hardened], plus Dart bytecode encoded with the
  /// release lineage's diversification profile. Bytecode interpreter releases
  /// only.
  hardenedDiversified('hardened-diversified');

  const SecurityProfile(this.value);

  /// The profile's name in `toolchain_security.json`, the bundled
  /// `shorebird.yaml`, `--security-profile` and SHOREBIRD_SECURITY_PROFILE.
  final String value;

  /// Whether every hardened rule applies ([hardened] and
  /// [hardenedDiversified]).
  bool get isHardened => this != SecurityProfile.legacy;

  /// The profile named [value], or null when [value] is not a profile.
  static SecurityProfile? tryParse(String value) => switch (value) {
    'legacy' => SecurityProfile.legacy,
    'hardened' => SecurityProfile.hardened,
    'hardened-diversified' => SecurityProfile.hardenedDiversified,
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
  'diversification_profile_id',
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

/// The path of the lineage's diversification profile (contract v3,
/// docs/HARDENING_CONTRACTS.md §11.2), which a hardened-diversified release or
/// patch passes to dart2bytecode as `--bytecode-profile`.
const diversificationProfileEnvironmentVariable =
    'SHOREBIRD_DIVERSIFICATION_PROFILE';

/// The diversification profile ID passed to `flutter build` from
/// `toolchain_security.json` (contract v3).
const diversificationProfileIdEnvironmentVariable =
    'SHOREBIRD_DIVERSIFICATION_PROFILE_ID';

/// The ID of the published DEVELOPMENT-ONLY diversification profile
/// (`scripts/testdata/diversification/profile.DEVELOPMENT-ONLY.json` in the
/// workspace). Its seed is public, so only development toolchains accept it.
const developmentDiversificationProfileId =
    'sha256:832856d0bed27833434e3f26b65d03cedc313f9850c2577ca7565c4dc644f46d';

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
    this.diversificationProfileId,
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
    final keys = switch (version) {
      1 => _keys,
      2 => _keysV2,
      _ => _keysV3,
    };
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
        'security_profile must be "legacy", "hardened" or '
        '"hardened-diversified", not ${jsonEncode(profileValue)}.',
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
    if (profile.isHardened && toolchainId == null) {
      fail('a hardened toolchain requires a toolchain_id.');
    }

    final developmentExceptions = decoded['development_exceptions'];
    if (developmentExceptions is! bool) {
      fail('development_exceptions must be true or false.');
    }

    String? releaseRoot;
    var minDelegationsVersion = 1;
    if (version >= 2) {
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
    if (profile.isHardened) {
      // Contract v2 (P4): the build manifest chains to a compiled release
      // root. A v1 hardened engine expects a bare manifest key instead.
      if (version == 1) {
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

    // Contract v3 (P5): exactly the diversified toolchains are v3.
    String? diversificationProfileId;
    if (profile == SecurityProfile.hardenedDiversified && version != 3) {
      fail(
        'a hardened-diversified toolchain needs contract_version 3 '
        '(diversification_profile_id).',
      );
    }
    if (version == 3) {
      if (profile != SecurityProfile.hardenedDiversified) {
        fail('contract_version 3 is used only by hardened-diversified.');
      }
      final id = decoded['diversification_profile_id'];
      if (id is! String || !isWellFormedToolchainId(id)) {
        fail(
          'diversification_profile_id must be "sha256:" followed by 64 '
          'lowercase hex digits, not ${jsonEncode(id)}.',
        );
      }
      if (id == developmentDiversificationProfileId && !developmentExceptions) {
        fail(
          'the DEVELOPMENT-ONLY diversification profile needs '
          'development_exceptions: true.',
        );
      }
      diversificationProfileId = id;
    }

    return ToolchainSecurity(
      profile: profile,
      toolchainId: toolchainId as String?,
      developmentExceptions: developmentExceptions,
      releaseRoot: releaseRoot,
      minDelegationsVersion: minDelegationsVersion,
      diversificationProfileId: diversificationProfileId,
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

  /// The contract version a hardened-diversified toolchain file must declare.
  static const diversifiedContractVersion = 3;

  /// The versions this CLI reads: 1 (legacy only), 2 (legacy or hardened)
  /// and 3 (hardened-diversified only).
  static const supportedContractVersions = [1, 2, 3];

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

  static const _keysV3 = {..._keysV2, 'diversification_profile_id'};

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

  /// The ID of the diversification profile the engine and dart2bytecode
  /// encode bytecode with. Set exactly for
  /// [SecurityProfile.hardenedDiversified].
  final String? diversificationProfileId;

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
    SecurityProfile.hardenedDiversified => {
      securityProfileEnvironmentVariable:
          SecurityProfile.hardenedDiversified.value,
      toolchainIdEnvironmentVariable: toolchainId!,
      releaseRootEnvironmentVariable: releaseRoot!,
      releaseMinDelegationsVersionEnvironmentVariable: '$minDelegationsVersion',
      diversificationProfileIdEnvironmentVariable: diversificationProfileId!,
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

/// Merges the release-record files `flutter build` wrote into [directory]
/// (one per distinct build manifest) into the one record stored with the
/// release (docs/HARDENING_CONTRACTS.md §10). Every file must agree on the
/// toolchain and the release trust; the build manifests are listed once each,
/// by digest.
///
/// A hardened release's records are `release-record.v2` and carry no
/// `diversification_profile_id`. A hardened-diversified release passes its
/// [diversificationProfileId]; its records must then be `release-record.v3`
/// (contract v3, §11.7) for that profile.
Map<String, Object?> readReleaseRecord(
  Directory directory, {
  String? diversificationProfileId,
}) {
  final expectedVersion = diversificationProfileId == null ? 2 : 3;
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
        decoded['contract_version'] != expectedVersion ||
        decoded['build_manifests'] is! List<Object?>) {
      throw ReleaseRecordException(
        '${file.path} is not a contract v$expectedVersion release record.',
      );
    }
    if (diversificationProfileId == null) {
      if (decoded.containsKey('diversification_profile_id')) {
        throw ReleaseRecordException(
          '${file.path} names a diversification profile, but this release is '
          'not hardened-diversified.',
        );
      }
    } else if (decoded['security_profile'] !=
            SecurityProfile.hardenedDiversified.value ||
        decoded['diversification_profile_id'] != diversificationProfileId) {
      throw ReleaseRecordException(
        '${file.path} is not a hardened-diversified record for '
        'diversification profile $diversificationProfileId.',
      );
    }
    final shared = Map<String, Object?>.of(decoded)..remove('build_manifests');
    if (merged == null) {
      merged = shared;
    } else if (jsonEncode(_sorted(merged)) != jsonEncode(_sorted(shared))) {
      throw ReleaseRecordException(
        'The release records in ${directory.path} disagree on the toolchain, '
        'the diversification profile or the release trust; every build of a '
        'release must be signed under the same delegations.',
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

/// Thrown when SHOREBIRD_DIVERSIFICATION_PROFILE does not name the profile
/// the toolchain was built with.
class BytecodeProfileException implements Exception {
  /// Creates a [BytecodeProfileException] with a complete-sentence [message].
  const BytecodeProfileException(this.message);

  /// What is wrong.
  final String message;

  @override
  String toString() => message;
}

/// {@template bytecode_profile}
/// The diversification profile (contract v3, docs/HARDENING_CONTRACTS.md
/// §11.2) a hardened-diversified release or patch encodes its Dart bytecode
/// with.
/// {@endtemplate}
class BytecodeProfile {
  /// {@macro bytecode_profile}
  const BytecodeProfile({required this.path, required this.id});

  /// Reads and validates the profile file at [path] (§11.2): the profile
  /// document's constants, a permutation of `0..N-1` with `N` at most 256,
  /// `Trap` kept at wire byte 0, fewer than 16 other fixed points, a null
  /// native layout and no duplicate JSON keys. Its ID is `sha256:` over the
  /// canonical JSON. dart2bytecode and the engine check the opcode table
  /// itself.
  factory BytecodeProfile.load(String path) {
    Never fail(String reason) => throw BytecodeProfileException(
      '$diversificationProfileEnvironmentVariable names $path, which $reason',
    );
    final String source;
    try {
      source = File(path).readAsStringSync();
    } on FileSystemException {
      fail('cannot be read.');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
      _rejectDuplicateKeys(source);
    } on FormatException catch (error) {
      fail('is not valid JSON (${error.message}).');
    }
    final problem = diversificationProfileProblem(decoded);
    if (problem != null) fail('is not a diversification profile: $problem');
    final digest = sha256.convert(utf8.encode(_canonicalJson(decoded)));
    return BytecodeProfile(path: p.absolute(path), id: 'sha256:$digest');
  }

  /// The absolute path of the profile file, passed to dart2bytecode.
  final String path;

  /// The profile ID: `sha256:` over the profile's canonical JSON.
  final String id;

  /// The 32 raw digest bytes of [id], as written in `DBP3` headers.
  List<int> get digest => [
    for (var i = 'sha256:'.length; i < id.length; i += 2)
      int.parse(id.substring(i, i + 2), radix: 16),
  ];

  /// The profile that [environment] names for [toolchain], a
  /// hardened-diversified toolchain. Throws a [BytecodeProfileException]
  /// when the variable is unset, the file is not a valid profile, its ID is
  /// not the one the toolchain was built with, or it is the DEVELOPMENT-ONLY
  /// profile and the toolchain is not a development toolchain.
  static BytecodeProfile forToolchain(
    Map<String, String> environment,
    ToolchainSecurity toolchain,
  ) {
    final path = environment[diversificationProfileEnvironmentVariable] ?? '';
    if (path.isEmpty) {
      throw const BytecodeProfileException(
        'Set $diversificationProfileEnvironmentVariable to the '
        "release lineage's diversification profile "
        '(scripts/diversification_profile.py new).',
      );
    }
    final profile = BytecodeProfile.load(path);
    if (profile.id != toolchain.diversificationProfileId) {
      throw BytecodeProfileException(
        '$diversificationProfileEnvironmentVariable names profile '
        '${profile.id}, but this toolchain was built with '
        '${toolchain.diversificationProfileId}.',
      );
    }
    if (profile.id == developmentDiversificationProfileId &&
        !toolchain.developmentExceptions) {
      throw const BytecodeProfileException(
        '$diversificationProfileEnvironmentVariable names the '
        'DEVELOPMENT-ONLY diversification profile, whose seed is public; '
        'only development toolchains accept it.',
      );
    }
    return profile;
  }
}

/// Why [document] is not a contract v3 diversification profile (§11.2), as
/// a sentence fragment, or null when it is one.
String? diversificationProfileProblem(Object? document) {
  bool exactKeys(Map<String, Object?> map, Set<String> keys) =>
      map.length == keys.length && map.keys.toSet().containsAll(keys);

  if (document is! Map<String, Object?> ||
      !exactKeys(document, const {
        'schema',
        'contract_version',
        'bytecode',
        'native_layout',
      })) {
    return 'expected exactly schema, contract_version, bytecode and '
        'native_layout.';
  }
  if (document['schema'] != 'open-shorebird.diversification-profile' ||
      document['contract_version'] != 3) {
    return 'schema must be open-shorebird.diversification-profile and '
        'contract_version 3.';
  }
  if (document['native_layout'] != null) {
    return 'native_layout is reserved and must be null.';
  }
  final bytecode = document['bytecode'];
  if (bytecode is! Map<String, Object?> ||
      !exactKeys(bytecode, const {
        'scheme',
        'format_version',
        'opcode_table_sha256',
        'wire_opcodes',
      })) {
    return 'bytecode must have exactly scheme, format_version, '
        'opcode_table_sha256 and wire_opcodes.';
  }
  if (bytecode['scheme'] != 'opcode-permutation-v1' ||
      bytecode['format_version'] != 3) {
    return 'bytecode must use scheme opcode-permutation-v1 and '
        'format_version 3.';
  }
  final table = bytecode['opcode_table_sha256'];
  if (table is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(table)) {
    return 'opcode_table_sha256 must be 64 lowercase hex digits.';
  }
  final wires = bytecode['wire_opcodes'];
  if (wires is! List<Object?> ||
      wires.length < 2 ||
      wires.any((wire) => wire is! int || wire < 0)) {
    return 'wire_opcodes must be at least two non-negative integers.';
  }
  if (wires.length > 256) {
    return 'at most 256 opcodes fit in one byte.';
  }
  final sorted = wires.cast<int>().toList()..sort();
  for (var i = 0; i < sorted.length; i++) {
    if (sorted[i] != i) {
      return 'wire_opcodes must be a permutation of 0..${wires.length - 1}.';
    }
  }
  if (wires[0] != 0) return 'Trap must keep wire byte 0.';
  var fixed = 0;
  for (var i = 1; i < wires.length; i++) {
    if (wires[i] == i) fixed++;
  }
  if (fixed >= _maxFixedPoints) {
    return 'it has $fixed fixed points; a derived profile has about one '
        '(at most ${_maxFixedPoints - 1} allowed).';
  }
  return null;
}

/// A derived permutation has about one fixed point besides Trap; this many
/// means a hand-made or degenerate map.
const _maxFixedPoints = 16;

/// Sorted keys, no insignificant whitespace (the reference
/// `canonical_json` of scripts/validate_hardening_contracts.py for the
/// integer, string and null values a profile holds).
String _canonicalJson(Object? value) => jsonEncode(_sorted(value));

/// Throws a [FormatException] when a JSON object in [source] (already known
/// to be valid JSON) repeats a key: `jsonDecode` would keep the last value,
/// so the ID could describe a map other tools read differently.
void _rejectDuplicateKeys(String source) {
  var i = 0;
  String readString() {
    final buffer = StringBuffer();
    i++; // Opening quote.
    while (source[i] != '"') {
      if (source[i] == r'\') {
        buffer.write(source.substring(i, i + 2));
        i += 2;
      } else {
        buffer.write(source[i++]);
      }
    }
    i++; // Closing quote.
    // Compare decoded keys, so an escaped and a plain spelling collide.
    return jsonDecode('"$buffer"') as String;
  }

  final keyStack = <Set<String>?>[];
  var expectKey = false;
  while (i < source.length) {
    final char = source[i];
    switch (char) {
      case '{':
        keyStack.add(<String>{});
        expectKey = true;
        i++;
      case '[':
        keyStack.add(null);
        expectKey = false;
        i++;
      case '}' || ']':
        keyStack.removeLast();
        expectKey = false;
        i++;
      case ',':
        expectKey = keyStack.isNotEmpty && keyStack.last != null;
        i++;
      case '"':
        final value = readString();
        if (expectKey) {
          if (!keyStack.last!.add(value)) {
            throw FormatException('duplicate key "$value"');
          }
          expectKey = false;
        }
      default:
        i++;
    }
  }
}
