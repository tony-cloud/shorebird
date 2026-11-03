import 'dart:convert';
import 'dart:io';

import 'package:open_aot_patch_tools/open_aot_patch_tools.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';

/// Names the `ios_linker` tool (a `.dart`, `.dill` or `.snapshot` run with the
/// vended Dart, or a native executable). Required by the `aot-link` profile.
const iosLinkerEnvVar = 'SHOREBIRD_IOS_LINKER';

/// A reference to an [IosLinker] instance.
final iosLinkerRef = create(IosLinker.new);

/// The [IosLinker] instance available in the current zone.
IosLinker get iosLinker => read(iosLinkerRef);

/// {@template ios_linker_exception}
/// `ios_linker` failed. [failure] is set for the documented exit codes.
/// {@endtemplate}
class IosLinkerException implements Exception {
  /// {@macro ios_linker_exception}
  const IosLinkerException({
    required this.command,
    required this.exitCode,
    required this.output,
    this.failBelow,
  });

  /// The `ios_linker` subcommand.
  final String command;

  /// The process exit code.
  final int exitCode;

  /// The tool's stderr and stdout.
  final String output;

  /// The configured `--min-link-percent`, for the message of exit code 3.
  final num? failBelow;

  /// The documented failure for [exitCode], if any.
  IosLinkerFailure? get failure => IosLinkerFailure.fromExitCode(exitCode);

  /// A message for the user.
  String get message =>
      failure?.describe(failBelow: failBelow, detail: output) ??
      'ios_linker $command failed with exit code $exitCode.\n${output.trim()}';

  @override
  String toString() => message;
}

/// What `ios_linker link` reports in its `--report` file.
class IosLinkReport {
  /// Creates a report.
  const IosLinkReport({
    required this.linkPercent,
    required this.patchCodeBytes,
    required this.linkedCodeBytes,
    required this.unlinkedEntries,
    required this.json,
  });

  /// Parses the report JSON.
  factory IosLinkReport.fromJson(Map<String, dynamic> json) => IosLinkReport(
    linkPercent: (json['link_percent'] as num).toDouble(),
    patchCodeBytes: json['patch_code_bytes'] as int,
    linkedCodeBytes: json['linked_code_bytes'] as int,
    unlinkedEntries: json['unlinked_entries'] as int,
    json: json,
  );

  /// Linked code bytes over patch code bytes, in percent.
  final double linkPercent;

  /// Code bytes of the patch.
  final int patchCodeBytes;

  /// Code bytes that run natively from the release.
  final int linkedCodeBytes;

  /// Entries that run in the simulator.
  final int unlinkedEntries;

  /// The whole report.
  final Map<String, dynamic> json;
}

/// Text image facts of a snapshot binary (`ios_linker info`).
class IosSnapshotInfo {
  /// Creates the info.
  const IosSnapshotInfo({
    required this.format,
    required this.textSize,
    required this.textSha256,
  });

  /// `macho` or `elf`.
  final String format;

  /// Bytes of `_kDartSnapshotText`.
  final int textSize;

  /// SHA-256 of `_kDartSnapshotText`.
  final String textSha256;
}

/// A wrapper around the `ios_linker` tool (tools/ios_linker).
class IosLinker {
  /// The path the tool is configured with, or null.
  String? get toolPath {
    final value = platform.environment[iosLinkerEnvVar]?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  /// The tool path, or an [IosLinkerException]-free [StateError] message the
  /// caller turns into a usage error.
  String requireToolPath() =>
      toolPath ??
      (throw StateError(
        'The aot-link profile needs the ios_linker tool: set $iosLinkerEnvVar '
        'to its .dart/.dill path or executable.',
      ));

  Future<ShorebirdProcessResult> _exec(List<String> arguments) {
    final tool = requireToolPath();
    final ext = p.extension(tool);
    final viaDart = ext == '.dart' || ext == '.dill' || ext == '.snapshot';
    return process.run(
      viaDart ? shorebirdEnv.dartBinaryFile.path : tool,
      [if (viaDart) tool, ...arguments],
      runInShell: false,
      useVendedFlutter: false,
    );
  }

  Future<String> _run(
    String command,
    List<String> arguments, {
    num? failBelow,
  }) async {
    final result = await _exec([command, ...arguments]);
    if (result.exitCode != 0) {
      throw IosLinkerException(
        command: command,
        exitCode: result.exitCode,
        output: '${result.stderr}${result.stdout}',
        failBelow: failBelow,
      );
    }
    return '${result.stdout}';
  }

  /// Links [patchElf] against the release [base] (`App.framework/App`).
  ///
  /// No vmcode is written below [minLinkPercent]; that raises an
  /// [IosLinkerException] whose failure is [IosLinkerFailure.belowMinimum].
  Future<IosLinkReport> link({
    required String base,
    required String baseLink,
    required String patchElf,
    required String patchLink,
    required String outVmcode,
    required String reportPath,
    num? minLinkPercent,
  }) async {
    await _run('link', [
      '--base',
      base,
      '--base-link',
      baseLink,
      '--patch-elf',
      patchElf,
      '--patch-link',
      patchLink,
      '--out',
      outVmcode,
      '--report',
      reportPath,
      if (minLinkPercent != null) ...['--min-link-percent', '$minLinkPercent'],
    ], failBelow: minLinkPercent);
    return IosLinkReport.fromJson(
      jsonDecode(File(reportPath).readAsStringSync()) as Map<String, dynamic>,
    );
  }

  /// Independently verifies [vmcode] against the release and the patch.
  Future<void> check({
    required String vmcode,
    required String base,
    required String patchElf,
    required String baseLink,
    required String patchLink,
    num? minLinkPercent,
  }) async {
    await _run('check', [
      '--vmcode',
      vmcode,
      '--base',
      base,
      '--patch-elf',
      patchElf,
      '--base-link',
      baseLink,
      '--patch-link',
      patchLink,
      if (minLinkPercent != null) ...['--min-link-percent', '$minLinkPercent'],
    ], failBelow: minLinkPercent);
  }

  /// Writes the release's data and text images, in the order the engine
  /// streams them to the updater, to [out].
  Future<void> diffBase({
    required String base,
    required String baseLink,
    required String out,
  }) async {
    await _run('diff-base', ['--base', base, '--link', baseLink, '--out', out]);
  }

  /// Reads the text image facts of [base].
  Future<IosSnapshotInfo> info({required String base, String? baseLink}) async {
    final out = await _run('info', [
      '--base',
      base,
      if (baseLink != null) ...['--link', baseLink],
    ]);
    final json = jsonDecode(out) as Map<String, dynamic>;
    return IosSnapshotInfo(
      format: json['format'] as String,
      textSize: json['text_size'] as int,
      textSha256: json['text_sha256'] as String,
    );
  }
}
