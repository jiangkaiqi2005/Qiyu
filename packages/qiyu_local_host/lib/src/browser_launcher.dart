/// 浏览器引导抽象接口：打开本机浏览器的平台实现由壳注入
/// （Windows 壳用 rundll32 调默认浏览器；安卓端内形态无浏览器引导）。
abstract interface class BrowserLauncher {
  Future<BrowserLaunchResult> open(Uri uri);
}

final class BrowserLaunchResult {
  const BrowserLaunchResult({
    required this.succeeded,
    required this.error,
    this.attempted = true,
  });

  const BrowserLaunchResult.skipped()
    : succeeded = false,
      error = null,
      attempted = false;

  final bool attempted;
  final bool succeeded;
  final String? error;
}
