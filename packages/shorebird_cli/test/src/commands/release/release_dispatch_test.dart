import 'package:args/command_runner.dart';
import 'package:shorebird_cli/src/commands/patch/patch_command.dart';
import 'package:shorebird_cli/src/commands/release/release_command.dart';
import 'package:shorebird_cli/src/commands/release/release_finalize_command.dart';
import 'package:shorebird_cli/src/extensions/arg_results.dart';
import 'package:test/test.dart';

import '../../helpers.dart';

class _Release extends ReleaseCommand {
  List<String>? dispatched;
  @override
  Future<int> run() async {
    dispatched = results.rest;
    return 17;
  }
}

class _Finalize extends ReleaseFinalizeCommand {
  List<String>? arches;
  @override
  Future<int> run() async {
    arches = results['arch'] as List<String>;
    return 23;
  }
}

class _Patch extends PatchCommand {
  List<String>? forwarded;
  @override
  Future<int> run() async {
    forwarded = results.forwardedArgs;
    return 29;
  }
}

void main() {
  useTempWorkingDirectory();
  test(
    'actual CommandRunner forwards explicit macOS x64 release and patch',
    () async {
      final release = _Release();
      final patch = _Patch();
      final runner = CommandRunner<int>('shorebird', 'test')
        ..addCommand(release)
        ..addCommand(patch);
      expect(
        await runner.run([
          'release',
          'macos',
          '--',
          '--target-platform=darwin-x64',
        ]),
        17,
      );
      expect(release.results.forwardedArgs, ['--target-platform=darwin-x64']);
      expect(
        await runner.run([
          'patch',
          'macos',
          '--release-version=1.0.0+1',
          '--variant=pro',
          '--',
          '--target-platform=darwin-x64',
        ]),
        29,
      );
      expect(patch.forwarded, ['--target-platform=darwin-x64']);
      expect(patch.results['variant'], 'pro');
    },
  );

  test(
    'actual CommandRunner dispatch preserves positional release platforms',
    () async {
      final release = _Release();
      final runner = CommandRunner<int>('shorebird', 'test')
        ..addCommand(release)
        ..addCommand(_Finalize());
      expect(await runner.run(['release', 'android']), 17);
      expect(release.dispatched, ['android']);
    },
  );
  test('actual CommandRunner dispatch preserves release --platforms', () async {
    final release = _Release();
    final runner = CommandRunner<int>('shorebird', 'test')
      ..addCommand(release)
      ..addCommand(_Finalize());
    expect(await runner.run(['release', '--platforms=linux']), 17);
    expect(release.results['platforms'], ['linux']);
  });
  test(
    'actual CommandRunner dispatch accepts explicit finalize architecture set',
    () async {
      final finalize = _Finalize();
      final runner = CommandRunner<int>('shorebird', 'test')
        ..addCommand(_Release())
        ..addCommand(finalize);
      expect(
        await runner.run([
          'release-finalize',
          '--platform=linux',
          '--release-version=1.0.0+1',
          '--arch=x86_64,aarch64',
        ]),
        23,
      );
      expect(finalize.arches, ['x86_64', 'aarch64']);
    },
  );
}
