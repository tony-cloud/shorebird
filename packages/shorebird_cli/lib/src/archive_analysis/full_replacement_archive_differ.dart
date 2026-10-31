import 'dart:convert';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:open_aot_patch_tools/open_aot_patch_tools.dart';
import 'package:shorebird_cli/src/archive_analysis/apple_archive_differ.dart';
import 'package:shorebird_cli/src/archive_analysis/file_set_diff.dart';
import 'package:yaml/yaml.dart';

/// Compares native archives built with the complete replacement profile.
///
/// A native comparison embeds a baseline projection of the current component.
/// Only that generated baseline and its policy digest are normalized. All
/// other policy, asset and native comparisons retain Apple's usual behavior.
class FullReplacementArchiveDiffer extends AppleArchiveDiffer {
  /// Creates a differ bound to the exact generated baseline wrapper hashes.
  const FullReplacementArchiveDiffer({
    required this.releaseBaseHash,
    required this.comparisonBaseHash,
  });

  /// SHA-256 of the original released baseline wrapper, not its component.
  final String releaseBaseHash;

  /// SHA-256 of the current component's baseline projection wrapper.
  final String comparisonBaseHash;

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
      if (bundle.normalizedPolicy == current.normalizedPolicy) {
        changed.remove(bundle.policyPath);
      } else {
        changed.add(bundle.policyPath);
      }
    }
    return FileSetDiff(
      addedPaths: diff.addedPaths,
      removedPaths: diff.removedPaths,
      changedPaths: changed,
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
        final baseline = FullReplacementBundle.decode(bytes).manifest;
        if (!baseline.isBaseline || baseline.hostAbiHex != host) {
          throw const FormatException(
            'Replacement asset must be a baseline bound to its compiled host.',
          );
        }
        final normalized = Map<String, Object?>.from(policy)
          ..remove('aot_patch_base_snapshot_hash');
        result.add(
          _BaselineAssets(
            policyPath: policyPath,
            basePath: basePath,
            hostAbi: host,
            rootUri: baseline.rootUri,
            normalizedPolicy: canonicalJson(normalized),
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
    required this.hostAbi,
    required this.rootUri,
    required this.normalizedPolicy,
  });

  final String policyPath;
  final String basePath;
  final String hostAbi;
  final String rootUri;
  final String normalizedPolicy;
}
