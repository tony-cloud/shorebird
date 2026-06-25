import 'package:json_annotation/json_annotation.dart';

part 'shorebird_yaml.g.dart';

/// The patch verification mode for the app.
@JsonEnum(fieldRename: FieldRename.snake)
enum PatchVerification {
  /// Verify the patch signature and hash before installing and loading.
  strict,

  /// Verify the patch signature and hash before installing, but not when
  /// loading from cache.
  installOnly,
}

/// {@template shorebird_yaml}
/// A Shorebird configuration file which contains metadata about the app.
/// {@endtemplate}
@JsonSerializable(anyMap: true, disallowUnrecognizedKeys: true)
class ShorebirdYaml {
  /// {@macro shorebird_yaml}
  const ShorebirdYaml({
    required this.appId,
    this.flavors,
    this.baseUrl,
    this.autoUpdate,
    this.patchVerification,
    this.aotPatchRuntimeMode,
    this.aotPatchBytecodePath,
    this.aotPatchKeyId,
    this.aotPatchKeyHex,
    this.aotPatchAppBuildId,
    this.aotPatchBaseFlavorId,
    this.aotPatchBaseLicenseType,
    this.aotPatchFlavorId,
    this.aotPatchLicenseType,
    this.aotPatchSdkHash,
    this.aotPatchBaseSnapshotHash,
    this.aotPatchObfuscationMapHash,
    this.aotPatchOfflineExpiresAt,
  });

  /// Creates a [ShorebirdYaml] from a JSON map.
  factory ShorebirdYaml.fromJson(Map<dynamic, dynamic> json) =>
      _$ShorebirdYamlFromJson(json);

  /// Converts this [ShorebirdYaml] to a JSON map.
  Map<String, dynamic> toJson() => _$ShorebirdYamlToJson(this);

  /// The base app id.
  ///
  /// Example:
  /// `"8d3155a8-a048-4820-acca-824d26c29b71"`
  final String appId;

  /// A map of flavor names to app ids.
  ///
  /// Will be `null` for apps with no flavors.
  ///
  /// Example:
  /// ```json
  /// {
  ///   "development": "8d3155a8-a048-4820-acca-824d26c29b71",
  ///   "production": "d458e87a-7362-4386-9eeb-629db2af413a"
  /// }
  /// ```
  final Map<String, String>? flavors;

  /// The base url used to check for updates.
  final String? baseUrl;

  /// Whether or not to automatically update the app.
  final bool? autoUpdate;

  /// The patch verification mode for the app.
  final PatchVerification? patchVerification;

  /// Runtime mode used for open AOT patch artifacts.
  final String? aotPatchRuntimeMode;

  /// Path to a full Dart bytecode patch payload for the iOS interpreter route.
  final String? aotPatchBytecodePath;

  /// Key id used to encrypt open AOT patch artifacts.
  final String? aotPatchKeyId;

  /// Development-only AES-256 key used to encrypt open AOT patch artifacts.
  final String? aotPatchKeyHex;

  /// App build id to bind into open AOT patch artifacts.
  final String? aotPatchAppBuildId;

  /// Optional source flavor id this patch can replace.
  final String? aotPatchBaseFlavorId;

  /// Optional source license type this patch can replace.
  final String? aotPatchBaseLicenseType;

  /// Target flavor id after the patch is applied.
  final String? aotPatchFlavorId;

  /// Target license type after the patch is applied.
  final String? aotPatchLicenseType;

  /// SDK hash expected by the runtime for open AOT patch artifacts.
  final String? aotPatchSdkHash;

  /// Base bytecode snapshot hash expected by the runtime.
  final String? aotPatchBaseSnapshotHash;

  /// Optional obfuscation map hash expected by the runtime.
  final String? aotPatchObfuscationMapHash;

  /// Optional offline expiration timestamp for the patch artifact.
  final String? aotPatchOfflineExpiresAt;
}

/// Extension on [ShorebirdYaml] to get the app id for a specific flavor.
extension AppIdExtension on ShorebirdYaml {
  /// Returns the app id for the given flavor.
  String getAppId({String? flavor}) {
    if (flavor == null || flavors == null) return appId;
    return flavors![flavor] ?? appId;
  }
}
