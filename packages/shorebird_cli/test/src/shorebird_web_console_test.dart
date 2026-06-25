import 'package:mocktail/mocktail.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_web_console.dart';
import 'package:test/test.dart';

import 'mocks.dart';

void main() {
  group(ShorebirdWebConsole, () {
    late ShorebirdEnv shorebirdEnv;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        () => body(),
        values: {shorebirdEnvRef.overrideWith(() => shorebirdEnv)},
      );
    }

    setUp(() {
      shorebirdEnv = MockShorebirdEnv();
      when(
        () => shorebirdEnv.hostedUri,
      ).thenReturn(Uri.parse(ShorebirdEnv.defaultHostedUrl));
    });

    test('uri returns the correct uri with the received path', () {
      expect(
        runWithOverrides(() => ShorebirdWebConsole.uri('path')),
        Uri.parse('${ShorebirdEnv.defaultHostedUrl}/path'),
      );
    });

    test('appReleaseUri returns the correct uri to an app release', () {
      expect(
        runWithOverrides(
          () => ShorebirdWebConsole.appReleaseUri('appId', 123),
        ),
        Uri.parse('${ShorebirdEnv.defaultHostedUrl}/apps/appId/releases/123'),
      );
    });

    test('uses the configured hosted url', () {
      when(
        () => shorebirdEnv.hostedUri,
      ).thenReturn(Uri.parse('https://open.example.com/base'));

      expect(
        runWithOverrides(() => ShorebirdWebConsole.uri('path')),
        Uri.parse('https://open.example.com/base/path'),
      );
    });
  });
}
