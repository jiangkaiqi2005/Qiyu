import 'dart:convert';
import 'dart:io';

import 'package:qiyu_windows_host/qiyu_windows_host.dart';

Future<void> main(List<String> arguments) async {
  HostLaunchResult? launch;
  // 命令行解析失败时不建呈现器：那只能来自脚本或开发者手输参数，
  // 不为它弹模态弹窗。--check 是脚本冒烟入口，同样只走命令行输出。
  StartupFailureReporter? failureReporter;
  try {
    final options = HostCommandOptions.parse(arguments);
    if (!options.checkOnly) {
      failureReporter = StartupFailureReporter(
        presenter: const WindowsMessageBoxPresenter(),
        logDirectoryPath: resolveHostRuntimeDirectory(
          environment: Platform.environment,
          overridePath: options.runtimeDirectory,
        ),
      );
    }
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
      // checkOnly 已提前返回，此处必有呈现器。
      failureReporter!.reportPreflightChecks(report.checks);
      stderr.writeln('栖语启动失败：启动前检查未通过');
      exitCode = 1;
      return;
    }

    final runtimeDirectory = resolveHostRuntimeDirectory(
      environment: Platform.environment,
      overridePath: options.runtimeDirectory,
    );
    final memoryDirectory = resolveHostMemoryDirectory(
      environment: Platform.environment,
      overridePath: options.memoryDirectory,
    );
    final personaConstitution = await File(
      resolvePersonaConstitutionPath(
        currentDirectory: Directory.current.path,
        executablePath: Platform.resolvedExecutable,
      ),
    ).readAsString();
    final personaConstitutionEnPath = tryResolvePersonaConstitutionEnPath(
      currentDirectory: Directory.current.path,
      executablePath: Platform.resolvedExecutable,
    );
    final personaConstitutionEn = personaConstitutionEnPath != null
        ? await File(personaConstitutionEnPath).readAsString()
        : null;
    launch = await QiyuHostRunner(
      webRoot: webRoot,
      runtimeDirectory: runtimeDirectory,
      memoryDirectory: memoryDirectory,
      personaConstitution: personaConstitution,
      personaConstitutionEn: personaConstitutionEn,
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
    failureReporter?.reportError(error);
    stderr.writeln('栖语启动失败：$error');
    exitCode = 1;
  } finally {
    await launch?.close();
  }
}
