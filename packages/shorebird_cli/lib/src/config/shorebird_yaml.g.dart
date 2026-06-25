// GENERATED CODE - DO NOT MODIFY BY HAND

// ignore_for_file: implicit_dynamic_parameter, require_trailing_commas, cast_nullable_to_non_nullable, lines_longer_than_80_chars, strict_raw_type, unnecessary_lambdas

part of 'shorebird_yaml.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ShorebirdYaml _$ShorebirdYamlFromJson(Map json) => $checkedCreate(
  'ShorebirdYaml',
  json,
  ($checkedConvert) {
    $checkKeys(
      json,
      allowedKeys: const [
        'app_id',
        'flavors',
        'base_url',
        'auto_update',
        'patch_verification',
        'aot_patch_runtime_mode',
        'aot_patch_bytecode_path',
        'aot_patch_key_id',
        'aot_patch_key_hex',
        'aot_patch_app_build_id',
        'aot_patch_base_flavor_id',
        'aot_patch_base_license_type',
        'aot_patch_flavor_id',
        'aot_patch_license_type',
        'aot_patch_sdk_hash',
        'aot_patch_base_snapshot_hash',
        'aot_patch_obfuscation_map_hash',
        'aot_patch_offline_expires_at',
      ],
    );
    final val = ShorebirdYaml(
      appId: $checkedConvert('app_id', (v) => v as String),
      flavors: $checkedConvert(
        'flavors',
        (v) => (v as Map?)?.map((k, e) => MapEntry(k as String, e as String)),
      ),
      baseUrl: $checkedConvert('base_url', (v) => v as String?),
      autoUpdate: $checkedConvert('auto_update', (v) => v as bool?),
      patchVerification: $checkedConvert(
        'patch_verification',
        (v) => $enumDecodeNullable(_$PatchVerificationEnumMap, v),
      ),
      aotPatchRuntimeMode: $checkedConvert(
        'aot_patch_runtime_mode',
        (v) => v as String?,
      ),
      aotPatchBytecodePath: $checkedConvert(
        'aot_patch_bytecode_path',
        (v) => v as String?,
      ),
      aotPatchKeyId: $checkedConvert('aot_patch_key_id', (v) => v as String?),
      aotPatchKeyHex: $checkedConvert(
        'aot_patch_key_hex',
        (v) => v as String?,
      ),
      aotPatchAppBuildId: $checkedConvert(
        'aot_patch_app_build_id',
        (v) => v as String?,
      ),
      aotPatchBaseFlavorId: $checkedConvert(
        'aot_patch_base_flavor_id',
        (v) => v as String?,
      ),
      aotPatchBaseLicenseType: $checkedConvert(
        'aot_patch_base_license_type',
        (v) => v as String?,
      ),
      aotPatchFlavorId: $checkedConvert(
        'aot_patch_flavor_id',
        (v) => v as String?,
      ),
      aotPatchLicenseType: $checkedConvert(
        'aot_patch_license_type',
        (v) => v as String?,
      ),
      aotPatchSdkHash: $checkedConvert(
        'aot_patch_sdk_hash',
        (v) => v as String?,
      ),
      aotPatchBaseSnapshotHash: $checkedConvert(
        'aot_patch_base_snapshot_hash',
        (v) => v as String?,
      ),
      aotPatchObfuscationMapHash: $checkedConvert(
        'aot_patch_obfuscation_map_hash',
        (v) => v as String?,
      ),
      aotPatchOfflineExpiresAt: $checkedConvert(
        'aot_patch_offline_expires_at',
        (v) => v as String?,
      ),
    );
    return val;
  },
  fieldKeyMap: const {
    'appId': 'app_id',
    'baseUrl': 'base_url',
    'autoUpdate': 'auto_update',
    'patchVerification': 'patch_verification',
    'aotPatchRuntimeMode': 'aot_patch_runtime_mode',
    'aotPatchBytecodePath': 'aot_patch_bytecode_path',
    'aotPatchKeyId': 'aot_patch_key_id',
    'aotPatchKeyHex': 'aot_patch_key_hex',
    'aotPatchAppBuildId': 'aot_patch_app_build_id',
    'aotPatchBaseFlavorId': 'aot_patch_base_flavor_id',
    'aotPatchBaseLicenseType': 'aot_patch_base_license_type',
    'aotPatchFlavorId': 'aot_patch_flavor_id',
    'aotPatchLicenseType': 'aot_patch_license_type',
    'aotPatchSdkHash': 'aot_patch_sdk_hash',
    'aotPatchBaseSnapshotHash': 'aot_patch_base_snapshot_hash',
    'aotPatchObfuscationMapHash': 'aot_patch_obfuscation_map_hash',
    'aotPatchOfflineExpiresAt': 'aot_patch_offline_expires_at',
  },
);

Map<String, dynamic> _$ShorebirdYamlToJson(
  ShorebirdYaml instance,
) => <String, dynamic>{
  'app_id': instance.appId,
  'flavors': instance.flavors,
  'base_url': instance.baseUrl,
  'auto_update': instance.autoUpdate,
  'patch_verification': _$PatchVerificationEnumMap[instance.patchVerification],
  'aot_patch_runtime_mode': instance.aotPatchRuntimeMode,
  'aot_patch_bytecode_path': instance.aotPatchBytecodePath,
  'aot_patch_key_id': instance.aotPatchKeyId,
  'aot_patch_key_hex': instance.aotPatchKeyHex,
  'aot_patch_app_build_id': instance.aotPatchAppBuildId,
  'aot_patch_base_flavor_id': instance.aotPatchBaseFlavorId,
  'aot_patch_base_license_type': instance.aotPatchBaseLicenseType,
  'aot_patch_flavor_id': instance.aotPatchFlavorId,
  'aot_patch_license_type': instance.aotPatchLicenseType,
  'aot_patch_sdk_hash': instance.aotPatchSdkHash,
  'aot_patch_base_snapshot_hash': instance.aotPatchBaseSnapshotHash,
  'aot_patch_obfuscation_map_hash': instance.aotPatchObfuscationMapHash,
  'aot_patch_offline_expires_at': instance.aotPatchOfflineExpiresAt,
};

const _$PatchVerificationEnumMap = {
  PatchVerification.strict: 'strict',
  PatchVerification.installOnly: 'install_only',
};
