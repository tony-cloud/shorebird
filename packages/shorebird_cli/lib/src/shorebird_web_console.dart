import 'package:shorebird_cli/src/shorebird_env.dart';

/// Shorebird Web Console URLs.
class ShorebirdWebConsole {
  /// Returns a [Uri] for the Shorebird Web Console.
  static Uri uri(String path) {
    final baseUri =
        shorebirdEnv.hostedUri ?? Uri.parse(ShorebirdEnv.defaultHostedUrl);
    final pathSegments = [
      ...baseUri.pathSegments.where((segment) => segment.isNotEmpty),
      ...path.split('/').where((segment) => segment.isNotEmpty),
    ];
    return baseUri.replace(
      pathSegments: pathSegments,
    );
  }

  /// Returns a [Uri] for the Shorebird Web Console login page.
  static Uri appReleaseUri(String appId, int releaseId) {
    return ShorebirdWebConsole.uri('apps/$appId/releases/$releaseId');
  }
}
