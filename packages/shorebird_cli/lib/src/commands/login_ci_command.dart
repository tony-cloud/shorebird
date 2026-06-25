import 'package:mason_logger/mason_logger.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';
import 'package:shorebird_cli/src/shorebird_documentation.dart';
import 'package:shorebird_cli/src/shorebird_web_console.dart';

/// {@template login_ci_command}
/// `shorebird login:ci`
/// Removed — directs users to API keys instead.
/// {@endtemplate}
class LoginCiCommand extends ShorebirdCommand {
  @override
  String get description => 'Removed — use API keys instead.';

  @override
  String get name => 'login:ci';

  @override
  Future<int> run() async {
    logger.err(
      '''
shorebird login:ci has been replaced by API keys.

Create an API key at ${link(uri: ShorebirdWebConsole.uri(''))} and set it as your ${lightCyan.wrap('SHOREBIRD_TOKEN')} environment variable.

Learn more: ${link(uri: Uri.parse('$docsUrl/account/api-keys/'))}''',
    );
    return ExitCode.usage.code;
  }
}
