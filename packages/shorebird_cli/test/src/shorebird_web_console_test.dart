import 'package:mocktail/mocktail.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_web_console.dart';
import 'package:test/test.dart';

import 'helpers.dart';
import 'mocks.dart';

void main() {
  useTempWorkingDirectory();
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

    group('appSettingsUri', () {
      test("returns the app's settings page under its organization", () {
        expect(
          runWithOverrides(
            () => ShorebirdWebConsole.appSettingsUri(
              organizationId: 7,
              appId: 'appId',
            ),
          ),
          Uri.parse('http://localhost:8080/orgs/7/apps/appId/settings'),
        );
      });

      test('returns the home page when the organization is unknown', () {
        expect(
          runWithOverrides(
            () => ShorebirdWebConsole.appSettingsUri(
              organizationId: null,
              appId: 'appId',
            ),
          ),
          Uri.parse('http://localhost:8080'),
        );
      });
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

    group('baseUri', () {
      test('is the production console by default', () {
        expect(
          runWithOverrides(() => ShorebirdWebConsole.baseUri),
          Uri.parse(defaultConsoleUrl),
        );
      });

      test('is the production console for another code push server', () {
        when(() => shorebirdEnv.hostedEnvironment).thenReturn(null);
        expect(
          runWithOverrides(() => ShorebirdWebConsole.baseUri),
          Uri.parse(defaultConsoleUrl),
        );
      });

      test('is the dev console for the dev code push server', () {
        when(() => shorebirdEnv.hostedEnvironment).thenReturn(devEnvironment);
        expect(
          runWithOverrides(() => ShorebirdWebConsole.baseUri),
          Uri.parse(devConsoleUrl),
        );
        expect(
          runWithOverrides(() => ShorebirdWebConsole.uri('account')),
          Uri.parse('https://console-dev.shorebird.dev/account'),
        );
      });
    });
  });
}
