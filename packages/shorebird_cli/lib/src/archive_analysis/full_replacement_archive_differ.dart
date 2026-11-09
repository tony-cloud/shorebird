import 'dart:convert';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:open_aot_patch_tools/open_aot_patch_tools.dart';
import 'package:shorebird_cli/src/archive_analysis/apple_archive_differ.dart';
import 'package:shorebird_cli/src/archive_analysis/apple_zip_validator.dart';
import 'package:shorebird_cli/src/archive_analysis/file_set_diff.dart';
import 'package:shorebird_cli/src/archive_analysis/shorebird_native_assets_descriptor.dart';
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';
import 'package:yaml/yaml.dart';

/// Compares native archives built with the complete replacement profile.
///
/// A native comparison embeds a baseline projection of the current component.
/// Only that generated baseline and its policy/scope digests are normalized.
/// All other policy, scope, asset and native comparisons retain Apple's usual
/// behavior.
class FullReplacementArchiveDiffer extends AppleArchiveDiffer {
  /// Creates a differ bound to the exact generated baseline wrapper hashes.
  const FullReplacementArchiveDiffer({
    required this.releaseBaseHash,
    required this.comparisonBaseHash,
    this.nativeAssetsTarget = 'ios_arm64',
  });

  /// SHA-256 of the original released baseline wrapper, not its component.
  final String releaseBaseHash;

  /// SHA-256 of the current component's baseline projection wrapper.
  final String comparisonBaseHash;

  /// Compiler mapping target bound to this Apple build route.
  final String nativeAssetsTarget;

  static const _baseAsset = 'shorebird_replacement_base.sbr';
  static final _hashPattern = RegExp(r'^[0-9a-f]{64}$');
  static final _policyPath = RegExp(r'(^|/)flutter_assets/shorebird\.yaml$');
  static final _basePath = RegExp(
    r'(^|/)flutter_assets/shorebird_replacement_base\.sbr$',
  );

  @override
  Future<FileSetDiff> changedFiles(
    String oldArchivePath,
    String newArchivePath,
  ) async {
    final released = await _readBaselines(oldArchivePath, releaseBaseHash);
    final comparison = await _readBaselines(newArchivePath, comparisonBaseHash);
    final identity = released.first;
    if ([...released, ...comparison].any(
      (bundle) =>
          bundle.hostAbi != identity.hostAbi ||
          bundle.rootUri != identity.rootUri,
    )) {
      throw const FormatException(
        'Native comparison replacement host ABI or root differs from release.',
      );
    }
    if ([...released, ...comparison].any(
      (bundle) => bundle.normalizedScope != identity.normalizedScope,
    )) {
      throw const FormatException(
        'Native comparison selection scope differs from release.',
      );
    }

    // Keep the inherited signature removal, Mach-O UUID handling and compiled
    // asset catalog comparison. Their hashes must not be replaced by raw CRCs.
    final diff = await super.changedFiles(oldArchivePath, newArchivePath);
    final changed = {...diff.changedPaths};
    final currentByPolicy = {
      for (final bundle in comparison) bundle.policyPath: bundle,
    };
    for (final bundle in released) {
      final current = currentByPolicy[bundle.policyPath];
      if (current == null) continue;
      changed.remove(bundle.basePath);
      if (bundle.scopePath != null && bundle.scopePath == current.scopePath) {
        changed.remove(bundle.scopePath);
      }
      if (bundle.normalizedPolicy == current.normalizedPolicy) {
        changed.remove(bundle.policyPath);
      } else {
        changed.add(bundle.policyPath);
      }
    }
    final unknown = <String>{
      for (final bundle in [...released, ...comparison])
        if (!bundle.hasNativeAssetsDescriptor)
          bundle.nativeAssetsDescriptorPath,
    };
    // Missing provenance is unknown, even if both old archives lack it. Route
    // this through native policy without claiming a verified byte difference.
    changed.addAll(unknown);
    final nativeDiff = diff as AppleFileSetDiff;
    return AppleFileSetDiff.fromDiff(
      FileSetDiff(
        addedPaths: diff.addedPaths.difference(unknown),
        removedPaths: diff.removedPaths.difference(unknown),
        changedPaths: changed,
      ),
      nativePaths: {...nativeDiff.nativePaths, ...unknown},
      nativeUncertaintyPaths: {
        ...nativeDiff.nativeUncertaintyPaths,
        ...unknown,
      },
    );
  }

  Future<List<_BaselineAssets>> _readBaselines(
    String archivePath,
    String expectedHash,
  ) async {
    if (!_hashPattern.hasMatch(expectedHash)) {
      throw const FormatException('Invalid expected replacement wrapper hash.');
    }
    final input = InputFileStream(archivePath);
    try {
      const validator = AppleZipValidator();
      validator.validate(input, validator.readDirectory(input));
      input.position = 0;
      final decoder = ZipDecoder();
      final archive = decoder.decodeStream(input);
      // Archive coalesces duplicate filenames, so count the original ZIP
      // headers before trusting the materialized policy and baseline entries.
      final headers = decoder.directory.fileHeaders;
      final policies = headers
          .where((file) => _policyPath.hasMatch(file.filename))
          .toList();
      final bases = headers
          .where((file) => _basePath.hasMatch(file.filename))
          .toList();
      if (headers.map((file) => file.filename).toSet().length !=
          headers.length) {
        throw const FormatException('Duplicate ZIP archive entries.');
      }
      if (policies.isEmpty || bases.length != policies.length) {
        throw const FormatException(
          'Full replacement archives require paired policies and baselines.',
        );
      }
      final basePaths = bases.map((file) => file.filename).toSet();
      final result = <_BaselineAssets>[];
      for (final policyHeader in policies) {
        final policyPath = policyHeader.filename;
        final basePath = policyPath.replaceFirst(
          RegExp(r'shorebird\.yaml$'),
          _baseAsset,
        );
        if (!basePaths.remove(basePath)) {
          throw const FormatException(
            'Replacement policy and baseline must share '
            'a Flutter asset bundle.',
          );
        }
        final nativeAssetsDescriptorPath = policyPath.replaceFirst(
          RegExp(r'shorebird\.yaml$'),
          ShorebirdNativeAssetsDescriptor.assetName,
        );
        final nativeAssetsDescriptor = archive.find(nativeAssetsDescriptorPath);
        if (nativeAssetsDescriptor != null) {
          ShorebirdNativeAssetsDescriptor.canonicalBody(
            nativeAssetsDescriptor,
            target: nativeAssetsTarget,
          );
          nativeAssetsDescriptor.clear();
        }
        final policyFile = archive.find(policyPath)!;
        final baseFile = archive.find(basePath)!;
        if (!policyFile.isFile ||
            policyFile.isSymbolicLink ||
            !baseFile.isFile ||
            baseFile.isSymbolicLink) {
          throw const FormatException(
            'Replacement assets must be regular files.',
          );
        }
        if (baseFile.size >
            24 + fullReplacementMaxManifest + fullReplacementMaxComponent) {
          throw const FormatException('Replacement baseline exceeds limit.');
        }
        final policy = loadYaml(utf8.decode(policyFile.content as List<int>));
        if (policy is! YamlMap || policy.keys.any((key) => key is! String)) {
          throw const FormatException('Invalid compiled replacement policy.');
        }
        final host = policy['aot_patch_host_abi'];
        final structural = policy['aot_patch_structural_updates'];
        if (policy['aot_patch_full_replacement'] != true ||
            policy['aot_patch_runtime_mode'] !=
                runtimeModeDartBytecodeInterpreter ||
            (structural != null && structural != false) ||
            host is! String ||
            !_hashPattern.hasMatch(host) ||
            policy['aot_patch_replacement_base'] != _baseAsset ||
            policy['aot_patch_base_snapshot_hash'] != expectedHash) {
          throw const FormatException(
            'Inconsistent compiled replacement policy.',
          );
        }
        // Consume lazy archive contents before closing the backing stream.
        final bytes = baseFile.content as List<int>;
        if (sha256.convert(bytes).toString() != expectedHash) {
          throw const FormatException(
            'Replacement baseline asset hash mismatch.',
          );
        }
        final baseline = FullReplacementBundle.decode(
          bytes,
          bytecodeProfileDigest: admittedBytecodeProfile?.digest,
        ).manifest;
        if (!baseline.isBaseline || baseline.hostAbiHex != host) {
          throw const FormatException(
            'Replacement asset must be a baseline bound to its compiled host.',
          );
        }
        final normalized = Map<String, Object?>.from(policy)
          ..remove('aot_patch_base_snapshot_hash');
        String? scopePath;
        String? normalizedScope;
        if (policy['selection_protocol'] == 2) {
          final platform = switch (nativeAssetsTarget) {
            'ios_arm64' => 'ios',
            'macos_arm64' || 'macos_x64' => 'macos',
            _ => throw const FormatException(
              'Unsupported native comparison selection target.',
            ),
          };
          final arch = nativeAssetsTarget == 'macos_x64' ? 'x86_64' : 'aarch64';
          scopePath = policyPath.replaceFirst(
            RegExp(r'shorebird\.yaml$'),
            'shorebird_release_scope_${platform}_$arch.json',
          );
          final scopeFile = archive.find(scopePath);
          if (scopeFile == null ||
              !scopeFile.isFile ||
              scopeFile.isSymbolicLink) {
            throw const FormatException(
              'Native comparison requires a regular selection scope asset.',
            );
          }
          final ReleaseSelectionScope scope;
          try {
            scope = ReleaseSelectionScope.decode(
              utf8.decode(scopeFile.content as List<int>),
            );
          } on Object {
            throw const FormatException(
              'Invalid native comparison selection scope.',
            );
          }
          // The expected wrapper hash was independently checked against the
          // actual asset above. Only this generated hash may differ; the other
          // six fields must match every released and comparison scope exactly.
          if (scope.baseArtifactHash != expectedHash ||
              scope.hostAbiHash != host ||
              scope.appId != policy['app_id'] ||
              scope.releaseVersion != policy['aot_patch_app_build_id'] ||
              scope.platform != platform ||
              scope.arch != arch ||
              scope.runtimeProfile != 'interpreter-full') {
            throw const FormatException(
              'Native comparison selection scope binding mismatch.',
            );
          }
          normalizedScope = canonicalJson(
            scope.toJson()..remove('base_artifact_hash'),
          );
          scopeFile.clear();
        }
        result.add(
          _BaselineAssets(
            policyPath: policyPath,
            basePath: basePath,
            nativeAssetsDescriptorPath: nativeAssetsDescriptorPath,
            hasNativeAssetsDescriptor: nativeAssetsDescriptor != null,
            hostAbi: host,
            rootUri: baseline.rootUri,
            normalizedPolicy: canonicalJson(normalized),
            scopePath: scopePath,
            normalizedScope: normalizedScope,
          ),
        );
      }
      return result;
    } finally {
      await input.close();
    }
  }
}

class _BaselineAssets {
  const _BaselineAssets({
    required this.policyPath,
    required this.basePath,
    required this.nativeAssetsDescriptorPath,
    required this.hasNativeAssetsDescriptor,
    required this.hostAbi,
    required this.rootUri,
    required this.normalizedPolicy,
    required this.scopePath,
    required this.normalizedScope,
  });

  final String policyPath;
  final String basePath;
  final String nativeAssetsDescriptorPath;
  final bool hasNativeAssetsDescriptor;
  final String hostAbi;
  final String rootUri;
  final String normalizedPolicy;
  final String? scopePath;
  final String? normalizedScope;
}
