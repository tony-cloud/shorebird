import 'dart:convert';
import 'dart:io';

import 'package:open_aot_patch_tools/open_aot_patch_tools.dart';

void main(List<String> args) {
  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    _usage();
    return;
  }

  final command = args.first;
  final options = _parse(args.skip(1).toList());
  switch (command) {
    case 'link':
      _link(options);
    case 'encrypt':
      _encrypt(options);
    case 'verify':
      _verify(options);
    case 'dump-blobs':
      _dumpBlobs(options);
    case 'compile-patch':
      _compilePatch(options);
    default:
      stderr.writeln('Unknown command: $command');
      _usage();
      exitCode = 64;
  }
}

void _link(Map<String, String> options) {
  final base = File(_required(options, 'base')).readAsBytesSync();
  final patch = File(_required(options, 'patch')).readAsBytesSync();
  final targetOs = _required(options, 'target-os');
  final runtimeMode = _runtimeModeForLink(options, targetOs);
  final metadata = PatchMetadata(
    appId: _required(options, 'app-id'),
    appBuildId: _required(options, 'app-build-id'),
    baseFlavorId: options['base-flavor-id'],
    baseLicenseType: options['base-license-type'],
    flavorId: _required(options, 'flavor-id'),
    licenseType: _required(options, 'license-type'),
    sdkHash: _required(options, 'sdk-hash'),
    baseSnapshotHash: sha256Hex(base),
    patchSnapshotHash: sha256Hex(patch),
    targetOs: targetOs,
    targetArch: _required(options, 'target-arch'),
    runtimeMode: runtimeMode,
    obfuscationMapHash: options['obfuscation-map-hash'],
    offlineExpiresAt: _optionalIso8601Utc(options['offline-expires-at']),
  );
  final artifact = linkArtifacts(
    baseSnapshot: base,
    patchSnapshot: patch,
    metadata: metadata,
    forceFullSnapshot: _boolOption(options, 'full-snapshot'),
  );
  File(_required(options, 'output')).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(artifact.toJson()),
  );
}

String _runtimeModeForLink(Map<String, String> options, String targetOs) {
  final runtimeMode = options['runtime-mode'];
  if (targetOs == 'ios' && (runtimeMode == null || runtimeMode.isEmpty)) {
    throw ArgumentError(
      'Missing --runtime-mode for iOS. Use '
      '--runtime-mode=$runtimeModeDartBytecodeInterpreter for App Store-safe '
      'interpreter patches, or explicitly pass '
      '--runtime-mode=$runtimeModeNativeAot for development-only native AOT '
      'artifacts.',
    );
  }
  final resolved = runtimeMode ?? runtimeModeNativeAot;
  if (!knownRuntimeModes.contains(resolved)) {
    throw ArgumentError('Unsupported --runtime-mode=$resolved');
  }
  return resolved;
}

void _encrypt(Map<String, String> options) {
  final artifact = PatchArtifact.fromJson(
    readJsonFile(File(_required(options, 'input'))),
  );
  final encrypted = encryptArtifact(
    artifact: artifact,
    keyId: _required(options, 'key-id'),
    key: readKey(_required(options, 'key-hex')),
    nonce: readNonce(_required(options, 'nonce-hex')),
  );
  File(_required(options, 'output')).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(encrypted.toJson()),
  );
}

void _verify(Map<String, String> options) {
  final input = File(_required(options, 'input'));
  final inputBytes = input.readAsBytesSync();
  _verifyArtifactHash(inputBytes, options['artifact-sha256']);
  final encrypted = EncryptedPatchArtifact.fromJson(
    (jsonDecode(utf8.decode(inputBytes)) as Map).cast<String, Object?>(),
  );
  verifyMetadata(
    encrypted.metadata,
    baseFlavorId: options['base-flavor-id'],
    baseLicenseType: options['base-license-type'],
    flavorId: _required(options, 'flavor-id'),
    licenseType: _required(options, 'license-type'),
    requireIosAppStoreSafe: _boolOption(options, 'require-ios-app-store-safe'),
    now: _optionalDateTime(options['now']),
    allowExpired: _boolOption(options, 'allow-expired'),
  );
  final decrypted = encrypted.decrypt(readKey(_required(options, 'key-hex')));
  final basePath = options['base'];
  if (basePath != null) {
    final reconstructed = decrypted.reconstruct(
      File(basePath).readAsBytesSync(),
    );
    final reconstructedHash = sha256Hex(reconstructed);
    if (reconstructedHash != decrypted.metadata.patchSnapshotHash) {
      throw StateError(
        'Reconstructed patch hash $reconstructedHash does not match metadata '
        '${decrypted.metadata.patchSnapshotHash}.',
      );
    }
  } else if (decrypted.payloadKind == payloadKindBinaryDiff) {
    stderr.writeln(
      'warning: compact binary diff decrypted, but --base was not provided; '
      'skipping reconstructed patch hash verification.',
    );
  }
}

void _verifyArtifactHash(List<int> bytes, String? expectedHash) {
  if (expectedHash == null) {
    return;
  }
  final actualHash = sha256Hex(bytes);
  if (actualHash != expectedHash) {
    throw StateError(
      'Artifact hash $actualHash does not match expected $expectedHash.',
    );
  }
}

void _dumpBlobs(Map<String, String> options) {
  final input = File(_required(options, 'input'));
  final bytes = input.readAsBytesSync();
  Map<String, Object?> report;
  try {
    final json = (jsonDecode(utf8.decode(bytes)) as Map)
        .cast<String, Object?>();
    final format = json['format'];
    if (format == artifactFormat) {
      final artifact = PatchArtifact.fromJson(json);
      _checkOfflineExpiry(artifact.metadata, options);
      final reconstructed = _maybeReconstruct(
        artifact,
        basePath: options['base'],
        outputPath: options['output'],
      );
      report = {
        'path': input.path,
        'format': artifactFormat,
        'artifact_sha256': sha256Hex(bytes),
        'metadata': artifact.metadata.toJson(),
        'payload_kind': artifact.payloadKind,
        'payload_size': artifact.payload.length,
        'payload_sha256': sha256Hex(artifact.payload),
        if (artifact.reconstructedSize != null)
          'reconstructed_size': artifact.reconstructedSize,
        if (reconstructed != null)
          'reconstructed_patch_size': reconstructed.length,
        if (reconstructed != null)
          'reconstructed_patch_sha256': sha256Hex(reconstructed),
        if (options['output'] != null) 'output': options['output'],
      };
    } else if (format == encryptedArtifactFormat) {
      final encrypted = EncryptedPatchArtifact.fromJson(json);
      report = {
        'path': input.path,
        'format': encryptedArtifactFormat,
        'artifact_sha256': sha256Hex(bytes),
        'metadata': encrypted.metadata.toJson(),
        'payload_kind': encrypted.payloadKind,
        'encrypted_payload_size': encrypted.encryptedPayload.length,
        'payload_sha256': encrypted.payloadSha256,
        'key_id': encrypted.keyId,
        if (encrypted.reconstructedSize != null)
          'reconstructed_size': encrypted.reconstructedSize,
      };
      final keyHex = options['key-hex'];
      if (keyHex != null) {
        final decrypted = encrypted.decrypt(readKey(keyHex));
        _checkOfflineExpiry(encrypted.metadata, options);
        final reconstructed = _maybeReconstruct(
          decrypted,
          basePath: options['base'],
          outputPath: options['output'],
        );
        report = {
          ...report,
          'decrypted_payload_size': decrypted.payload.length,
          'decrypted_payload_sha256': sha256Hex(decrypted.payload),
          if (reconstructed != null)
            'reconstructed_patch_size': reconstructed.length,
          if (reconstructed != null)
            'reconstructed_patch_sha256': sha256Hex(reconstructed),
          if (options['output'] != null) 'output': options['output'],
        };
      } else if (options['output'] != null) {
        throw const FormatException(
          'Encrypted artifacts require --key-hex when --output is used.',
        );
      }
    } else {
      throw const FormatException('not an open AOT patch artifact');
    }
  } on FormatException {
    if (options['key-hex'] != null || options['output'] != null) {
      rethrow;
    }
    report = {
      'path': input.path,
      'format': 'raw',
      'size': bytes.length,
      'sha256': sha256Hex(bytes),
    };
  }
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
}

void _checkOfflineExpiry(
  PatchMetadata metadata,
  Map<String, String> options,
) {
  if (_boolOption(options, 'allow-expired')) {
    return;
  }
  if (metadata.isOfflineExpired(now: _optionalDateTime(options['now']))) {
    throw StateError(
      'Patch offline license expired at ${metadata.offlineExpiresAt}.',
    );
  }
}

List<int>? _maybeReconstruct(
  PatchArtifact artifact, {
  required String? basePath,
  required String? outputPath,
}) {
  if (basePath == null && artifact.payloadKind != payloadKindFullSnapshot) {
    if (outputPath != null) {
      throw const FormatException(
        'Compact artifacts require --base when --output is used.',
      );
    }
    return null;
  }

  final base = basePath == null
      ? const <int>[]
      : File(basePath).readAsBytesSync();
  final reconstructed = artifact.reconstruct(base);
  if (sha256Hex(reconstructed) != artifact.metadata.patchSnapshotHash) {
    throw StateError(
      'Reconstructed patch hash does not match metadata '
      '${artifact.metadata.patchSnapshotHash}.',
    );
  }
  if (outputPath != null) {
    File(outputPath).writeAsBytesSync(reconstructed);
  }
  return reconstructed;
}

void _compilePatch(Map<String, String> options) {
  final genSnapshot = _required(options, 'gen-snapshot');
  final kernel = _required(options, 'kernel');
  final output = _required(options, 'output');
  final snapshotKind = options['snapshot-kind'] ?? 'app-aot-elf';
  final args = <String>['--snapshot-kind=$snapshotKind'];
  switch (snapshotKind) {
    case 'app-aot-elf':
      args.add('--elf=$output');
    case 'app-aot-macho-dylib':
      args.add('--macho=$output');
      final machoObject = options['macho-object'];
      if (machoObject != null) {
        args.add('--macho-object=$machoObject');
      }
    case 'app-aot-assembly':
      args.add('--assembly=$output');
    default:
      throw ArgumentError('Unsupported --snapshot-kind=$snapshotKind');
  }
  if (_boolOption(options, 'strip', defaultValue: true)) {
    args.add('--strip');
  }
  final loadObfuscationMap = options['load-obfuscation-map'];
  final saveObfuscationMap = options['save-obfuscation-map'];
  if (_boolOption(options, 'obfuscate') ||
      loadObfuscationMap != null ||
      saveObfuscationMap != null) {
    args.add('--obfuscate');
  }
  if (loadObfuscationMap != null) {
    args.add('--load-obfuscation-map=$loadObfuscationMap');
  }
  if (saveObfuscationMap != null) {
    args.add('--save-obfuscation-map=$saveObfuscationMap');
  }
  args.add(kernel);

  final result = Process.runSync(genSnapshot, args);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    throw ProcessException(
      genSnapshot,
      args,
      'gen_snapshot failed',
      result.exitCode,
    );
  }
}

Map<String, String> _parse(List<String> args) {
  final parsed = <String, String>{};
  for (final arg in args) {
    if (!arg.startsWith('--') || !arg.contains('=')) {
      throw ArgumentError('Expected --name=value, got $arg');
    }
    final separator = arg.indexOf('=');
    parsed[arg.substring(2, separator)] = arg.substring(separator + 1);
  }
  return parsed;
}

String _required(Map<String, String> options, String name) {
  final value = options[name];
  if (value == null || value.isEmpty) {
    throw ArgumentError('Missing --$name');
  }
  return value;
}

bool _boolOption(
  Map<String, String> options,
  String name, {
  bool defaultValue = false,
}) {
  final value = options[name];
  if (value == null) return defaultValue;
  return value == 'true' || value == '1' || value == 'yes';
}

DateTime? _optionalDateTime(String? value) {
  if (value == null || value.isEmpty) return null;
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw ArgumentError('Expected ISO-8601 timestamp, got $value');
  }
  return parsed.toUtc();
}

String? _optionalIso8601Utc(String? value) {
  final parsed = _optionalDateTime(value);
  return parsed?.toIso8601String();
}

void _usage() {
  stdout.writeln('''
Usage:
  open_aot_patch_tools dump-blobs --input=<file> [--key-hex=<64 hex chars>] [--base=<file>] [--output=<vmcode>] [--now=<iso8601>] [--allow-expired=true]
  open_aot_patch_tools compile-patch --gen-snapshot=<path> --kernel=<dill> --output=<file> [--snapshot-kind=app-aot-elf|app-aot-macho-dylib|app-aot-assembly] [--macho-object=<file>] [--obfuscate=true] [--load-obfuscation-map=<file>] [--save-obfuscation-map=<file>]
  open_aot_patch_tools link --base=<file> --patch=<file> --output=<file> --app-id=<id> --app-build-id=<id> --flavor-id=<id> --license-type=<type> --sdk-hash=<hash> --target-os=<os> --target-arch=<arch> [--runtime-mode=native-aot|dart-bytecode-interpreter] [--base-flavor-id=<id>] [--base-license-type=<type>] [--obfuscation-map-hash=<sha256>] [--offline-expires-at=<iso8601>] [--full-snapshot=true]
  open_aot_patch_tools encrypt --input=<file> --output=<file> --key-id=<id> --key-hex=<64 hex chars> --nonce-hex=<24 hex chars>
  open_aot_patch_tools verify --input=<file> --key-hex=<64 hex chars> --flavor-id=<id> --license-type=<type> [--base=<file>] [--artifact-sha256=<sha256>] [--base-flavor-id=<id>] [--base-license-type=<type>] [--require-ios-app-store-safe=true] [--now=<iso8601>] [--allow-expired=true]
''');
}
