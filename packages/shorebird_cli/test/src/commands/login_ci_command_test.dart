import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/auth/auth.dart';
import 'package:shorebird_cli/src/commands/commands.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:test/test.dart';

import '../mocks.dart';

void main() {
  group(LoginCiCommand, () {
    late Auth auth;
    late ShorebirdLogger logger;
    late ShorebirdEnv shorebirdEnv;
    late LoginCiCommand command;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        body,
        values: {
          authRef.overrideWith(() => auth),
          loggerRef.overrideWith(() => logger),
          shorebirdEnvRef.overrideWith(() => shorebirdEnv),
        },
      );
    }

    setUp(() {
      auth = MockAuth();
      logger = MockShorebirdLogger();
      shorebirdEnv = MockShorebirdEnv();
      when(
        () => shorebirdEnv.hostedUri,
      ).thenReturn(Uri.parse(ShorebirdEnv.defaultHostedUrl));

      command = runWithOverrides(LoginCiCommand.new);
    });

    test('has correct name', () {
      expect(command.name, equals('login:ci'));
    });

    test('has correct description', () {
      expect(command.description, contains('Removed'));
    });

    test('errors with usage exit code and points to API keys', () async {
      final result = await runWithOverrides(command.run);

      expect(result, equals(ExitCode.usage.code));

      final captured = verify(
        () => logger.err(captureAny()),
      ).captured;

      final message = captured.single as String;
      expect(message, contains('shorebird login:ci has been replaced'));
      expect(message, contains(ShorebirdEnv.defaultHostedUrl));
      expect(message, contains('SHOREBIRD_TOKEN'));
      expect(
        message,
        contains(
          'git.tonycloud.org/flutter/shorebird/src/branch/main/docs/account/api-keys',
        ),
      );
    });

    test('does not trigger any auth flow', () async {
      await runWithOverrides(command.run);

      verifyNoMoreInteractions(auth);
    });
  });
}
