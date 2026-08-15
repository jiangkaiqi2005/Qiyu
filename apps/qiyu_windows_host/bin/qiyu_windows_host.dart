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
    final memoryDirectory = resolveHostMemoryDirectory(
      environment: Platform.environment,
      overridePath: options.memoryDirectory,
    );
    final productSoul = await File(
      resolveProductSoulPath(
        currentDirectory: Directory.current.path,
        executablePath: Platform.resolvedExecutable,
      ),
    ).readAsString();
    launch = await QiyuHostRunner(
      webRoot: webRoot,
      runtimeDirectory: runtimeDirectory,
      memoryDirectory: memoryDirectory,
      productSoul: productSoul,
      browserLauncher: const WindowsDefaultBrowserLauncher(),
    ).launch(openBrowser: options.openBrowser);

    final state = launch.isPrimary ? '栖语已启动' : '栖语已在运行';
    // 登录 URL 里的 startup token 是会话凭据，仅在浏览器没能自动打开、
    // 或显式 --no-browser 需要手动访问时才输出，避免落入终端缓冲与日志。
    if (launch.browserLaunch.succeeded) {
      stdout.writeln(state);
    } else if (launch.browserLaunch.attempted) {
      stdout.writeln(state);
      stdout.writeln('无法自动打开浏览器，请手动访问：${launch.displayUri}');
    } else {
      stdout.writeln('$state：${launch.displayUri}');
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
