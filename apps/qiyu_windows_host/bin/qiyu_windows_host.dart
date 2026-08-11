import 'dart:convert';
import 'dart:io';

import 'package:qiyu_windows_host/qiyu_windows_host.dart';

Future<void> main(List<String> arguments) async {
  HostLaunchResult? launch;
  try {
    final options = HostCommandOptions.parse(arguments);
    final webRoot = resolveHostWebRoot(
      currentDirectory: Directory.current.path,
      executablePath: Platform.resolvedExecutable,
      overridePath: options.webRoot,
    );
    final report = runHostPreflight(
      operatingSystem: Platform.operatingSystem,
      webRoot: webRoot,
    );
    if (options.checkOnly) {
      stdout.writeln(jsonEncode(report.toJson()));
      if (!report.ready) {
        exitCode = 1;
      }
      return;
    }
    if (!report.ready) {
      throw StateError('Windows 本机宿主启动前检查失败');
    }

    final runtimeDirectory = resolveHostRuntimeDirectory(
      environment: Platform.environment,
      overridePath: options.runtimeDirectory,
    );
    launch = await QiyuHostRunner(
      webRoot: webRoot,
      runtimeDirectory: runtimeDirectory,
      browserLauncher: const WindowsDefaultBrowserLauncher(),
    ).launch(openBrowser: options.openBrowser);

    final state = launch.isPrimary ? '栖语已启动' : '栖语已在运行';
    stdout.writeln('$state：${launch.displayUri}');
    if (launch.browserLaunch.attempted && !launch.browserLaunch.succeeded) {
      stdout.writeln('无法自动打开浏览器，请复制上面的本机地址。');
    }
    if (!launch.isPrimary) {
      return;
    }

    await ProcessSignal.sigint.watch().first;
  } on Object catch (error) {
    stderr.writeln('栖语启动失败：$error');
    exitCode = 1;
  } finally {
    await launch?.close();
  }
}
