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
/// hardened build (hardening P3, docs/HARDENING_CONTRACTS.md §9). Its public
/// key must be compiled into the hardened engine
/// (`shorebird_build_manifest_keys`). `flutter build` reads it directly.
const buildManifestSigningKeyEnvironmentVariable =
    'SHOREBIRD_BUILD_MANIFEST_SIGNING_KEY';

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
  final keyPath = environment[buildManifestSigningKeyEnvironmentVariable] ?? '';
  if (keyPath.isEmpty) {
    problems.add(
      'Set $buildManifestSigningKeyEnvironmentVariable to the Ed25519 '
      'build-manifest signing key (PKCS#8 PEM) whose public key this hardened '
      'toolchain was built with.',
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

    final unknown = decoded.keys.toSet().difference(_keys);
    if (unknown.isNotEmpty) fail('unknown keys ${unknown.join(', ')}.');
    final missing = _keys.difference(decoded.keys.toSet());
    if (missing.isNotEmpty) fail('missing keys ${missing.join(', ')}.');

    if (decoded['schema'] != schema) fail('schema must be "$schema".');
    final version = decoded['contract_version'];
    if (version is! int || version != contractVersion) {
      fail(
        'unsupported contract_version $version; this Shorebird CLI '
        'understands only $contractVersion.',
      );
    }

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

    return ToolchainSecurity(
      profile: profile,
      toolchainId: toolchainId as String?,
      developmentExceptions: developmentExceptions,
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

  /// The only contract version this CLI understands.
  static const contractVersion = 1;

  static const _keys = {
    'schema',
    'contract_version',
    'security_profile',
    'toolchain_id',
    'development_exceptions',
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
