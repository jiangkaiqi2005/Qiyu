import 'dart:io';

import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;
  late Directory webRoot;
  late Directory runtimeDirectory;
  late Directory memoryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-host-runner-test-',
    );
    webRoot = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}web',
    )..createSync();
    runtimeDirectory = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}runtime',
    );
    memoryDirectory = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}memories',
    );
    File(
      '${webRoot.path}${Platform.pathSeparator}index.html',
    ).writeAsStringSync('<!doctype html><title>栖语</title>');
  });

  tearDown(() async {
    if (temporaryDirectory.existsSync()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test(
    'a second launch activates the existing host instead of starting another',
    () async {
      final primaryBrowser = _RecordingBrowserLauncher();
      final primary = await QiyuHostRunner(
        webRoot: webRoot.path,
        runtimeDirectory: runtimeDirectory.path,
        memoryDirectory: memoryDirectory.path,
        browserLauncher: primaryBrowser,
      ).launch();

      expect(primary.isPrimary, isTrue);
      expect(primary.host, isNotNull);
      expect(primaryBrowser.openedUris, [primary.displayUri]);

      final secondaryBrowser = _RecordingBrowserLauncher();
      final secondary = await QiyuHostRunner(
        webRoot: webRoot.path,
        runtimeDirectory: runtimeDirectory.path,
        memoryDirectory: memoryDirectory.path,
        browserLauncher: secondaryBrowser,
      ).launch();

      expect(secondary.isPrimary, isFalse);
      expect(secondary.host, isNull);
      expect(secondary.origin, primary.origin);
      expect(primaryBrowser.openedUris, [
        primary.displayUri,
        primary.displayUri,
      ]);
      expect(secondaryBrowser.openedUris, isEmpty);

      await secondary.close();
      await primary.close();
    },
  );

  test('browser launch failure returns a copyable local URL', () async {
    final browser = _RecordingBrowserLauncher(succeeds: false);
    final launch = await QiyuHostRunner(
      webRoot: webRoot.path,
      runtimeDirectory: runtimeDirectory.path,
      memoryDirectory: memoryDirectory.path,
      browserLauncher: browser,
    ).launch();

    expect(launch.isPrimary, isTrue);
    expect(launch.browserLaunch.succeeded, isFalse);
    expect(launch.displayUri.host, InternetAddress.loopbackIPv4.address);
    expect(launch.displayUri.queryParameters['token'], isNotEmpty);

    await launch.close();
  });
}

final class _RecordingBrowserLauncher implements BrowserLauncher {
  _RecordingBrowserLauncher({this.succeeds = true});

  final bool succeeds;
  final List<Uri> openedUris = [];

  @override
  Future<BrowserLaunchResult> open(Uri uri) async {
    openedUris.add(uri);
    return BrowserLaunchResult(
      succeeded: succeeds,
      error: succeeds ? null : 'mock browser failure',
    );
  }
}
