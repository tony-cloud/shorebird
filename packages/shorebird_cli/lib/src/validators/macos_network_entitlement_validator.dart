import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/platform/apple/plist.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/validators/validators.dart';

/// Checks that the macOS app has the network client entitlement. Without this
/// entitlement, the app will not be able to make network requests, and
/// Shorebird will not be able to check for patches.
class MacosEntitlementsValidator extends Validator {
  /// The entitlements plist key for the Outgoing Connections (Client)
  /// entitlement, which allows macOS apps to make network requests.
  static const networkClientEntitlementKey =
      'com.apple.security.network.client';

  /// The entitlements plist key for the Allow Unsigned Executable Memory
  /// entitlement, which allows the app to run code not included in the original
  /// binary (e.g. patches).
  static const allowUnsignedExecutableMemoryKey =
      'com.apple.security.cs.allow-unsigned-executable-memory';

  // These are Boolean grants. Absence or explicit false disables the grant;
  // every other value is rejected rather than guessing at codesign semantics.
  static const _forbiddenInterpreterEntitlements = [
    'com.apple.security.cs.allow-jit',
    allowUnsignedExecutableMemoryKey,
    'com.apple.security.cs.disable-executable-page-protection',
    'com.apple.security.cs.disable-library-validation',
    'com.apple.security.cs.allow-dyld-environment-variables',
    'com.apple.security.cs.debugger',
    'com.apple.security.get-task-allow',
    'get-task-allow',
  ];

  bool get _requiresInterpreterEntitlements {
    final yaml = shorebirdEnv.getShorebirdYaml();
    // Incomplete interpreter requests must not be repaired into executable
    // patching policy either. Release validation rejects unsupported profiles.
    return yaml?.aotPatchRuntimeMode == 'dart-bytecode-interpreter' ||
        (yaml?.aotPatchFullReplacement ?? false);
  }

  Directory? get _macosDirectory {
    final projectRoot = shorebirdEnv.getFlutterProjectRoot();
    if (projectRoot == null) {
      return null;
    }

    return Directory(p.join(projectRoot.path, 'macos'));
  }

  /// The entitlements plist file for the release build. This lives in
  /// project_root/macos/Runner/Release.entitlements, where "Runner" may have
  /// been renamed.
  File? get _releaseEntitlementsPlist {
    final entitlementParentCandidateDirectories = _macosDirectory!
        .listSync()
        .whereType<Directory>();

    for (final appDir in entitlementParentCandidateDirectories) {
      final entitlementsPlist = File(
        p.join(appDir.path, 'Release.entitlements'),
      );

      if (entitlementsPlist.existsSync()) {
        return entitlementsPlist;
      }
    }

    return null;
  }

  @override
  String get description => 'macOS app has correct entitlements';

  @override
  bool canRunInCurrentContext() => _macosDirectory?.existsSync() ?? false;

  @override
  String? get incorrectContextMessage =>
      '''
The ${_macosDirectory?.path ?? 'macos'} directory does not exist.

The command you are running must be run within a Flutter app project that supports the macOS platform.''';

  @override
  Future<List<ValidationIssue>> validate() async {
    if (_releaseEntitlementsPlist == null) {
      return [
        const ValidationIssue(
          severity: ValidationIssueSeverity.error,
          message: 'Unable to find a Release.entitlements file',
        ),
      ];
    }

    final plistFile = _releaseEntitlementsPlist!;
    final properties = Plist(file: plistFile).properties;
    final interpreter = _requiresInterpreterEntitlements;
    return [
      for (final MapEntry(key: key, value: name)
          in _requiredEntitlements.entries)
        if ((!interpreter || key == networkClientEntitlementKey) &&
            properties[key] != true)
          ValidationIssue(
            severity: ValidationIssueSeverity.error,
            message:
                '${plistFile.path} is missing the $name ($key) entitlement.',
            fix: () {
              // Doctor may apply a previously reported native-mode fix after
              // shorebird.yaml changed. Never enable an interpreter exception.
              if (_forbiddenInterpreterEntitlements.contains(key) &&
                  _requiresInterpreterEntitlements) {
                throw Exception(
                  'Cannot enable $key for a macOS interpreter release.',
                );
              }
              addEntitlementToPlist(plistFile, key: key);
            },
          ),
      if (interpreter)
        for (final key in _forbiddenInterpreterEntitlements)
          if (properties.containsKey(key) && properties[key] != false)
            ValidationIssue(
              severity: ValidationIssueSeverity.error,
              message:
                  '${plistFile.path} enables or has an invalid value for $key. '
                  'Full interpreter releases forbid this entitlement; remove '
                  'it or set it to Boolean false.',
            ),
    ];
  }

  /// The entitlements Shorebird needs, mapped to their display names.
  static const _requiredEntitlements = {
    networkClientEntitlementKey: 'Outgoing Connections',
    allowUnsignedExecutableMemoryKey: 'Allow Unsigned Executable Memory',
  };

  /// Whether the given entitlements plist file has the entitlement [key].
  @visibleForTesting
  static bool hasEntitlement({required File plistFile, required String key}) =>
      Plist(file: plistFile).properties[key] == true;

  /// Adds the entitlement [key] to the given entitlements plist file.
  @visibleForTesting
  static void addEntitlementToPlist(
    File entitlementsPlist, {
    required String key,
  }) {
    final plist = Plist(file: entitlementsPlist);
    plist.properties[key] = true;
    entitlementsPlist.writeAsStringSync(plist.toString());
  }
}
