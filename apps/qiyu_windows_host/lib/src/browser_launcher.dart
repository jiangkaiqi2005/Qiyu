import 'dart:io';

import 'package:qiyu_local_host/qiyu_local_host.dart';

final class WindowsDefaultBrowserLauncher implements BrowserLauncher {
  const WindowsDefaultBrowserLauncher();

  @override
  Future<BrowserLaunchResult> open(Uri uri) async {
    if (!Platform.isWindows) {
      return const BrowserLaunchResult(
        succeeded: false,
        error: '当前平台不是 Windows',
      );
    }
    try {
      await Process.start('rundll32.exe', [
        'url.dll,FileProtocolHandler',
        uri.toString(),
      ], mode: ProcessStartMode.detached);
      return const BrowserLaunchResult(succeeded: true, error: null);
    } on ProcessException {
      return const BrowserLaunchResult(
        succeeded: false,
        error: '无法调用 Windows 默认浏览器',
      );
    }
  }
}
