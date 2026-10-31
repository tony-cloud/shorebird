// Allowing one member abstracts for consistency/namespace/ease of testing.
// ignore_for_file: one_member_abstracts

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/cache.dart';
import 'package:shorebird_cli/src/engine_config.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';

/// All Shorebird artifacts used explicitly by Shorebird.
enum ShorebirdArtifact {
  /// The iOS analyze_snapshot executable.
  analyzeSnapshotIos,

  /// The macOS analyze_snapshot executable that reads arm64 snapshots.
  analyzeSnapshotMacosArm64,

  /// The macOS analyze_snapshot executable that reads x64 snapshots.
  analyzeSnapshotMacosX64,

  /// The aot_tools executable or kernel file.
  aotTools,

  /// The gen_snapshot executable for iOS.
  genSnapshotIos,

  /// The exact device Flutter engine executable selected for iOS release.
  iosEngineBinary,

  /// The gen_snapshot executable for macOS that creates arm64 snapshots.
  genSnapshotMacosArm64,

  /// The gen_snapshot executable for macOS that creates x64 snapshots.
  genSnapshotMacosX64,

  /// The host dartaotruntime executable.
  dartAotRuntime,

  /// The host dart2bytecode snapshot.
  dart2BytecodeSnapshot,

  /// The Flutter product platform dill used to compile Flutter bytecode.
  flutterProductPlatformDill,
}

/// A reference to a [ShorebirdArtifacts] instance.
final shorebirdArtifactsRef = create<ShorebirdArtifacts>(
  ShorebirdCachedArtifacts.new,
);

/// The [ShorebirdArtifacts] instance available in the current zone.
ShorebirdArtifacts get shorebirdArtifacts => read(shorebirdArtifactsRef);

/// {@template shorebird_artifacts}
/// A class that provides access to Shorebird artifacts.
/// {@endtemplate}
abstract class ShorebirdArtifacts {
  /// Returns the path to the given [artifact].
  String getArtifactPath({required ShorebirdArtifact artifact});
}

/// {@template shorebird_cached_artifacts}
/// A class that provides access to cached Shorebird artifacts.
/// {@endtemplate}
class ShorebirdCachedArtifacts implements ShorebirdArtifacts {
  /// {@macro shorebird_cached_artifacts}
  const ShorebirdCachedArtifacts();

  @override
  String getArtifactPath({required ShorebirdArtifact artifact}) {
    switch (artifact) {
      case ShorebirdArtifact.analyzeSnapshotIos:
        return _analyzeSnapshotIosFile.path;
      case ShorebirdArtifact.analyzeSnapshotMacosArm64:
        return _analyzeSnapshotMacosFile('arm64').path;
      case ShorebirdArtifact.analyzeSnapshotMacosX64:
        return _analyzeSnapshotMacosFile('x64').path;
      case ShorebirdArtifact.aotTools:
        return _aotToolsFile.path;
      case ShorebirdArtifact.genSnapshotIos:
        return _genSnapshotIosFile.path;
      case ShorebirdArtifact.iosEngineBinary:
        return _iosEngineBinaryFile.path;
      case ShorebirdArtifact.genSnapshotMacosArm64:
        return _genSnapshotMacOsArm64File.path;
      case ShorebirdArtifact.genSnapshotMacosX64:
        return _genSnapshotMacOsX64File.path;
      case ShorebirdArtifact.dartAotRuntime:
        return _dartAotRuntimeFile.path;
      case ShorebirdArtifact.dart2BytecodeSnapshot:
        return _dart2BytecodeSnapshotFile.path;
      case ShorebirdArtifact.flutterProductPlatformDill:
        return _flutterProductPlatformDillFile.path;
    }
  }

  File get _analyzeSnapshotIosFile {
    return File(
      p.join(
        shorebirdEnv.flutterDirectory.path,
        'bin',
        'cache',
        'artifacts',
        'engine',
        'ios-release',
        'analyze_snapshot_arm64',
      ),
    );
  }

  File _analyzeSnapshotMacosFile(String targetArch) {
    final fileName = AnalyzeSnapshotMacosArtifact.fileNameFor(targetArch);
    return File(
      p.join(
        cache.getArtifactDirectory(fileName).path,
        shorebirdEnv.shorebirdEngineRevision,
        fileName,
      ),
    );
  }

  File get _aotToolsFile {
    const executableName = 'aot-tools';
    final kernelFile = File(
      p.join(
        cache.getArtifactDirectory(executableName).path,
        shorebirdEnv.shorebirdEngineRevision,
        '$executableName.dill',
      ),
    );
    if (kernelFile.existsSync()) {
      return kernelFile;
    }

    // We shipped aot-tools as an executable in the past, so we return that if
    // no kernel file is found.
    return File(
      p.join(
        cache.getArtifactDirectory(executableName).path,
        shorebirdEnv.shorebirdEngineRevision,
        executableName,
      ),
    );
  }

  File get _iosEngineBinaryFile => _iosEngineBinary(
    p.join(
      shorebirdEnv.flutterDirectory.path,
      'bin',
      'cache',
      'artifacts',
      'engine',
      'ios-release',
    ),
  );

  File get _genSnapshotIosFile {
    return File(
      p.join(
        shorebirdEnv.flutterDirectory.path,
        'bin',
        'cache',
        'artifacts',
        'engine',
        'ios-release',
        'gen_snapshot_arm64',
      ),
    );
  }

  File get _genSnapshotMacOsArm64File {
    return File(
      p.join(
        shorebirdEnv.flutterDirectory.path,
        'bin',
        'cache',
        'artifacts',
        'engine',
        'darwin-x64-release',
        'gen_snapshot_arm64',
      ),
    );
  }

  File get _genSnapshotMacOsX64File {
    return File(
      p.join(
        shorebirdEnv.flutterDirectory.path,
        'bin',
        'cache',
        'artifacts',
        'engine',
        'darwin-x64-release',
        'gen_snapshot_x64',
      ),
    );
  }

  File get _dartAotRuntimeFile {
    return File(
      p.join(
        shorebirdEnv.flutterDirectory.path,
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        'dartaotruntime',
      ),
    );
  }

  File get _dart2BytecodeSnapshotFile {
    return File(
      p.join(
        shorebirdEnv.flutterDirectory.path,
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        'snapshots',
        'dart2bytecode.dart.snapshot',
      ),
    );
  }

  File get _flutterProductPlatformDillFile {
    return File(
      p.join(
        shorebirdEnv.flutterDirectory.path,
        'bin',
        'cache',
        'artifacts',
        'engine',
        'common',
        'flutter_patched_sdk_product',
        'platform_strong.dill',
      ),
    );
  }
}

/// {@template shorebird_local_engine_artifacts}
/// A class that provides access to locally built Shorebird artifacts.
/// {@endtemplate}
class ShorebirdLocalEngineArtifacts implements ShorebirdArtifacts {
  /// {@macro shorebird_local_engine_artifacts}
  const ShorebirdLocalEngineArtifacts();

  @override
  String getArtifactPath({required ShorebirdArtifact artifact}) {
    switch (artifact) {
      case ShorebirdArtifact.analyzeSnapshotIos:
        return _analyzeSnapshotIosFile.path;
      case ShorebirdArtifact.analyzeSnapshotMacosArm64:
        return _analyzeSnapshotMacosFile('arm64').path;
      case ShorebirdArtifact.analyzeSnapshotMacosX64:
        return _analyzeSnapshotMacosFile('x64').path;
      case ShorebirdArtifact.aotTools:
        return _aotToolsFile.path;
      case ShorebirdArtifact.genSnapshotIos:
        return _genSnapshotIosFile.path;
      case ShorebirdArtifact.iosEngineBinary:
        return _iosEngineBinaryFile.path;
      case ShorebirdArtifact.genSnapshotMacosArm64:
        return _genSnapshotMacosArm64File.path;
      case ShorebirdArtifact.genSnapshotMacosX64:
        return _genSnapshotMacosX64File.path;
      case ShorebirdArtifact.dartAotRuntime:
        return _dartAotRuntimeFile.path;
      case ShorebirdArtifact.dart2BytecodeSnapshot:
        return _dart2BytecodeSnapshotFile.path;
      case ShorebirdArtifact.flutterProductPlatformDill:
        return _flutterProductPlatformDillFile.path;
    }
  }

  File get _analyzeSnapshotIosFile {
    return File(
      p.join(
        engineConfig.localEngineSrcPath!,
        'out',
        engineConfig.localEngine,
        'clang_x64',
        'analyze_snapshot_arm64',
      ),
    );
  }

  File _analyzeSnapshotMacosFile(String targetArch) {
    return File(
      p.join(
        engineConfig.localEngineSrcPath!,
        'out',
        engineConfig.localEngine,
        'analyze_snapshot_$targetArch',
      ),
    );
  }

  File get _aotToolsFile {
    return File(
      p.join(
        engineConfig.localEngineSrcPath!,
        'flutter',
        'third_party',
        'dart',
        'pkg',
        'aot_tools',
        'bin',
        'aot_tools.dart',
      ),
    );
  }

  File get _iosEngineBinaryFile => _iosEngineBinary(
    p.join(
      engineConfig.localEngineSrcPath!,
      'out',
      engineConfig.localEngine,
    ),
  );

  File get _genSnapshotIosFile => _localIosExecutable('gen_snapshot_arm64');

  File _localIosExecutable(String name) {
    // Keep the candidate order identical to Flutter's LocalEngineArtifacts.
    const directories = [
      '.',
      'universal',
      'clang_x64',
      'clang_x86',
      'clang_i386',
      'clang_arm64',
      'clang_riscv64',
    ];
    for (final directory in directories) {
      final file = File(
        p.normalize(
          p.join(
            engineConfig.localEngineSrcPath!,
            'out',
            engineConfig.localEngine,
            directory,
            name,
          ),
        ),
      );
      final stat = file.statSync();
      if (stat.type == FileSystemEntityType.file && (stat.mode & 0x49) != 0) {
        return file;
      }
    }
    throw StateError(
      'Unable to find executable $name for the local iOS engine',
    );
  }

  File get _genSnapshotMacosArm64File {
    return File(
      p.join(
        engineConfig.localEngineSrcPath!,
        'out',
        engineConfig.localEngine,
        'artifacts_arm64',
        'gen_snapshot',
      ),
    );
  }

  File get _genSnapshotMacosX64File {
    return File(
      p.join(
        engineConfig.localEngineSrcPath!,
        'out',
        engineConfig.localEngine,
        'artifacts_x64',
        'gen_snapshot',
      ),
    );
  }

  File get _dartAotRuntimeFile {
    final localEngineHost = engineConfig.localEngineHost;
    if (localEngineHost == null) {
      throw StateError(
        'localEngineHost is required for local engine artifacts',
      );
    }
    return File(
      p.join(
        engineConfig.localEngineSrcPath!,
        'out',
        localEngineHost,
        'dartaotruntime',
      ),
    );
  }

  File get _dart2BytecodeSnapshotFile {
    final localEngineHost = engineConfig.localEngineHost;
    if (localEngineHost == null) {
      throw StateError(
        'localEngineHost is required for local engine artifacts',
      );
    }
    return File(
      p.join(
        engineConfig.localEngineSrcPath!,
        'out',
        localEngineHost,
        'dart-sdk',
        'bin',
        'snapshots',
        'dart2bytecode.dart.snapshot',
      ),
    );
  }

  File get _flutterProductPlatformDillFile {
    final localEngine = engineConfig.localEngine;
    if (localEngine == null) {
      throw StateError('localEngine is required for local engine artifacts');
    }
    return File(
      p.join(
        engineConfig.localEngineSrcPath!,
        'out',
        localEngine,
        'flutter_patched_sdk',
        'platform_strong.dill',
      ),
    );
  }
}

// Match Flutter's first physical-device xcframework slice selection.
File _iosEngineBinary(String engineDirectory) {
  final xcframework = Directory(p.join(engineDirectory, 'Flutter.xcframework'));
  if (xcframework.existsSync()) {
    for (final directory in xcframework.listSync().whereType<Directory>()) {
      final name = p.basename(directory.path);
      if (name.startsWith('ios-') && !name.endsWith('-simulator')) {
        return File(p.join(directory.path, 'Flutter.framework', 'Flutter'));
      }
    }
  }
  return File(
    p.join(
      xcframework.path,
      'ios-arm64',
      'Flutter.framework',
      'Flutter',
    ),
  );
}
