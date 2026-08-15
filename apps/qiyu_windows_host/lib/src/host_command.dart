import 'dart:io';

import 'package:path/path.dart' as path;

final class HostCommandOptions {
  const HostCommandOptions({
    required this.checkOnly,
    required this.openBrowser,
    required this.webRoot,
    required this.runtimeDirectory,
    required this.memoryDirectory,
  });

  final bool checkOnly;
  final bool openBrowser;
  final String? webRoot;
  final String? runtimeDirectory;
  final String? memoryDirectory;

  static HostCommandOptions parse(List<String> arguments) {
    var checkOnly = false;
    var openBrowser = true;
    String? webRoot;
    String? runtimeDirectory;
    String? memoryDirectory;

    for (var index = 0; index < arguments.length; index += 1) {
      switch (arguments[index]) {
        case '--check':
          checkOnly = true;
        case '--no-browser':
          openBrowser = false;
        case '--web-root':
          webRoot = _readValue(arguments, ++index, '--web-root');
        case '--runtime-dir':
          runtimeDirectory = _readValue(arguments, ++index, '--runtime-dir');
        case '--memory-dir':
          memoryDirectory = _readValue(arguments, ++index, '--memory-dir');
        default:
          throw FormatException('未知参数：${arguments[index]}');
      }
    }

    return HostCommandOptions(
      checkOnly: checkOnly,
      openBrowser: openBrowser,
      webRoot: webRoot,
      runtimeDirectory: runtimeDirectory,
      memoryDirectory: memoryDirectory,
    );
  }

  static String _readValue(List<String> arguments, int index, String option) {
    if (index >= arguments.length || arguments[index].startsWith('--')) {
      throw FormatException('$option 缺少路径');
    }
    return arguments[index];
  }
}

String resolveHostMemoryDirectory({
  required Map<String, String> environment,
  String? overridePath,
}) {
  final configured = overridePath ?? environment['QIYU_MEMORY_DIR'];
  if (configured != null && configured.isNotEmpty) {
    return path.normalize(path.absolute(configured));
  }
  final userProfile = environment['USERPROFILE'];
  if (userProfile == null || userProfile.isEmpty) {
    throw StateError('找不到用户目录，请设置 QIYU_MEMORY_DIR。');
  }
  return path.join(userProfile, '.qiyu', 'memories');
}

String resolveHostWebRoot({
  required String currentDirectory,
  required String executablePath,
  String? overridePath,
}) {
  final candidates = overridePath == null
      ? [
          path.join(path.dirname(executablePath), 'web'),
          path.join(currentDirectory, '..', 'qiyu_flutter', 'build', 'web'),
          path.join(currentDirectory, 'apps', 'qiyu_flutter', 'build', 'web'),
        ]
      : [overridePath];

  for (final candidate in candidates) {
    final absoluteCandidate = path.normalize(path.absolute(candidate));
    if (File(path.join(absoluteCandidate, 'index.html')).existsSync()) {
      return absoluteCandidate;
    }
  }
  throw FileSystemException('找不到 Flutter Web 构建产物，请先运行 flutter build web');
}

String resolveHostRuntimeDirectory({
  required Map<String, String> environment,
  String? overridePath,
}) {
  if (overridePath != null) {
    return path.normalize(path.absolute(overridePath));
  }
  final localAppData = environment['LOCALAPPDATA'];
  if (localAppData != null && localAppData.isNotEmpty) {
    return path.join(localAppData, 'Qiyu', 'runtime');
  }
  return path.join(Directory.systemTemp.path, 'Qiyu', 'runtime');
}

String resolvePersonaConstitutionPath({
  required String currentDirectory,
  required String executablePath,
}) {
  final candidates = [
    path.join(path.dirname(executablePath), 'persona-constitution.md'),
    path.join(currentDirectory, '栖语人格宪法.md'),
    path.join(currentDirectory, '..', '..', '栖语人格宪法.md'),
  ];
  for (final candidate in candidates) {
    final absoluteCandidate = path.normalize(path.absolute(candidate));
    if (File(absoluteCandidate).existsSync()) {
      return absoluteCandidate;
    }
  }
  throw FileSystemException('找不到栖语人格宪法.md，无法启动模型聊天');
}
