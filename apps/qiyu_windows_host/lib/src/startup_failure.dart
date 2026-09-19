import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'host_command.dart';
import 'single_instance.dart';

/// 启动失败的稳定原因分类，决定弹窗与日志里的人话说明。
enum StartupFailureReason {
  /// Web 页面资源缺失或不完整（解压不完整、构建产物缺失）。
  webAssetsMissing,

  /// 人格宪法等包内必要文件缺失。
  constitutionMissing,

  /// 找不到存放记忆的本机用户目录。
  memoryDirectoryUnavailable,

  /// 当前操作系统不是 Windows。
  unsupportedPlatform,

  /// 启动自检未通过（程序文件可能不完整或损坏）。
  selfCheckFailed,

  /// 已有实例持有锁但无法激活。
  instanceConflict,

  /// 其余未预期失败。
  unexpected,
}

/// 一次启动失败的人话呈现：原因分类加一段可直接照做的说明。
final class StartupFailure {
  const StartupFailure(this.reason);

  final StartupFailureReason reason;

  /// 弹窗与运行目录日志共用的同一份说明。
  /// 只写人话与下一步，绝不透出本机路径或异常原文。
  String get userMessage => switch (reason) {
        StartupFailureReason.webAssetsMissing =>
          '栖语的页面文件缺失或不完整，通常是压缩包没有完整解压。'
              '请重新解压完整的安装包，再运行其中的栖语程序。',
        StartupFailureReason.constitutionMissing =>
          '栖语的人格配置文件缺失，通常是压缩包没有完整解压。'
              '请重新解压完整的安装包，再运行其中的栖语程序。',
        StartupFailureReason.memoryDirectoryUnavailable =>
          '栖语找不到存放记忆的本机目录，通常与当前 Windows 账户有关。'
              '请重新运行栖语；若仍然失败，请联系维护者。',
        StartupFailureReason.unsupportedPlatform =>
          '栖语目前只支持在 Windows 上运行。',
        StartupFailureReason.selfCheckFailed =>
          '栖语启动自检未通过，程序文件可能不完整。'
              '请重新解压完整的安装包，再运行其中的栖语程序。',
        StartupFailureReason.instanceConflict =>
          '栖语似乎已经在运行，但暂时连不上它。'
              '请稍候再运行一次；若仍然失败，请结束正在运行的栖语程序后重试。',
        StartupFailureReason.unexpected =>
          '启动时遇到问题，暂时没有更具体的原因。'
              '请重新运行栖语；若仍然失败，请在反馈问题时提供'
              '运行目录里的启动日志（${StartupFailureReporter.logFileName}）。',
      };
}

/// 把启动路径上抛出的异常映射为人话原因。只认本壳自己抛出的已知异常，
/// 其余一律归入未预期，异常原文与路径不进入弹窗或日志。
StartupFailure classifyStartupFailure(Object error) {
  if (error is FileSystemException) {
    if (error.message == webAssetsMissingFailureMessage) {
      return const StartupFailure(StartupFailureReason.webAssetsMissing);
    }
    if (error.message == personaConstitutionMissingFailureMessage) {
      return const StartupFailure(StartupFailureReason.constitutionMissing);
    }
  }
  // LocalAppHost.start 对缺失的 Web 根目录抛 ArgumentError。
  if (error is ArgumentError && error.name == 'webRoot') {
    return const StartupFailure(StartupFailureReason.webAssetsMissing);
  }
  if (error is StateError) {
    final message = error.message;
    if (message == userDirectoryMissingFailureMessage) {
      return const StartupFailure(
        StartupFailureReason.memoryDirectoryUnavailable,
      );
    }
    if (message.startsWith(existingInstanceFailurePrefix)) {
      return const StartupFailure(StartupFailureReason.instanceConflict);
    }
  }
  return const StartupFailure(StartupFailureReason.unexpected);
}

/// 把启动自检报告的检查结果映射为人话原因，取首要可行动项。
StartupFailure classifyPreflightChecks(Map<String, bool> checks) {
  if (checks['supportedPlatform'] == false) {
    return const StartupFailure(StartupFailureReason.unsupportedPlatform);
  }
  if (checks['behaviorCore'] == false) {
    return const StartupFailure(StartupFailureReason.selfCheckFailed);
  }
  if (checks['webAssets'] == false) {
    return const StartupFailure(StartupFailureReason.webAssetsMissing);
  }
  return const StartupFailure(StartupFailureReason.unexpected);
}

/// 启动失败的人话呈现接缝：默认实现弹原生弹窗，测试注入 fake 断言。
/// 弹窗只用于宿主启动失败，不扩大到其他失败路径。
abstract interface class StartupFailurePresenter {
  void present(StartupFailure failure);
}

/// 默认呈现：Windows 原生 MessageBox 弹窗。非 Windows 平台（开发与
/// 测试环境）保持安静，失败信息仍走命令行错误输出。FFI 弹窗无法在
/// 自动化测试里调用（会真弹窗阻塞），这正是呈现接缝存在的原因。
final class WindowsMessageBoxPresenter implements StartupFailurePresenter {
  const WindowsMessageBoxPresenter();

  @override
  void present(StartupFailure failure) {
    if (!Platform.isWindows) {
      return;
    }
    using((arena) {
      MessageBox(
        null,
        arena.pcwstr(failure.userMessage),
        arena.pcwstr('栖语启动失败'),
        MB_OK | MB_ICONERROR | MB_SETFOREGROUND | MB_TOPMOST,
      );
    });
  }
}

/// 启动失败呈现编排：同一份人话原因先写入运行目录日志，再交给呈现器。
/// 日志按次追加保留历史，写不进去时安静放弃，不挡弹窗与退出码。
final class StartupFailureReporter {
  StartupFailureReporter({
    required this.presenter,
    required this.logDirectoryPath,
  });

  static const String logFileName = 'startup-failure.log';

  final StartupFailurePresenter presenter;
  final String logDirectoryPath;

  void report(StartupFailure failure) {
    _appendLog(failure);
    presenter.present(failure);
  }

  void reportError(Object error) => report(classifyStartupFailure(error));

  void reportPreflightChecks(Map<String, bool> checks) =>
      report(classifyPreflightChecks(checks));

  void _appendLog(StartupFailure failure) {
    try {
      final directory = Directory(logDirectoryPath)..createSync(recursive: true);
      final stamp = DateTime.now().toUtc().toIso8601String();
      File('${directory.path}${Platform.pathSeparator}$logFileName')
          .writeAsStringSync(
        '$stamp [${failure.reason.name}] ${failure.userMessage}\n',
        mode: FileMode.append,
        flush: true,
      );
    } on Object {
      // 日志只是反馈证据，写失败不阻断弹窗。
    }
  }
}
