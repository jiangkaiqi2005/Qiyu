import 'dart:convert';
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
        personaConstitution: '测试人格宪法',
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
        personaConstitution: '测试人格宪法',
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
      personaConstitution: '测试人格宪法',
      browserLauncher: browser,
    ).launch();

    expect(launch.isPrimary, isTrue);
    expect(launch.browserLaunch.succeeded, isFalse);
    expect(launch.displayUri.host, InternetAddress.loopbackIPv4.address);
    expect(launch.displayUri.queryParameters['token'], isNotEmpty);

    await launch.close();
  });

  test('no-browser launch keeps single-instance activation headless', () async {
    final primaryBrowser = _RecordingBrowserLauncher();
    final primary = await QiyuHostRunner(
      webRoot: webRoot.path,
      runtimeDirectory: runtimeDirectory.path,
      memoryDirectory: memoryDirectory.path,
      personaConstitution: '测试人格宪法',
      browserLauncher: primaryBrowser,
    ).launch(openBrowser: false);
    HostLaunchResult? secondary;
    HostLaunchResult? interactive;
    try {
      secondary = await QiyuHostRunner(
        webRoot: webRoot.path,
        runtimeDirectory: runtimeDirectory.path,
        memoryDirectory: memoryDirectory.path,
        personaConstitution: '测试人格宪法',
        browserLauncher: _RecordingBrowserLauncher(),
      ).launch(openBrowser: false);

      expect(secondary.isPrimary, isFalse);
      expect(primaryBrowser.openedUris, isEmpty);

      interactive = await QiyuHostRunner(
        webRoot: webRoot.path,
        runtimeDirectory: runtimeDirectory.path,
        memoryDirectory: memoryDirectory.path,
        personaConstitution: '测试人格宪法',
        browserLauncher: _RecordingBrowserLauncher(),
      ).launch();
      expect(interactive.isPrimary, isFalse);
      expect(primaryBrowser.openedUris, [primary.displayUri]);
    } finally {
      await interactive?.close();
      await secondary?.close();
      await primary.close();
    }
  });

  test(
    'refuses to activate an instance whose descriptor points outside loopback',
    () async {
      final primary = await QiyuHostRunner(
        webRoot: webRoot.path,
        runtimeDirectory: runtimeDirectory.path,
        memoryDirectory: memoryDirectory.path,
        personaConstitution: '测试人格宪法',
        browserLauncher: _RecordingBrowserLauncher(),
      ).launch();
      expect(primary.isPrimary, isTrue);

      final descriptorFile = File(
        '${runtimeDirectory.path}${Platform.pathSeparator}instance.json',
      );
      final json =
          jsonDecode(descriptorFile.readAsStringSync())
              as Map<String, Object?>;
      json['origin'] = 'http://evil.example:8080';
      descriptorFile.writeAsStringSync(jsonEncode(json));

      final secondary = QiyuHostRunner(
        webRoot: webRoot.path,
        runtimeDirectory: runtimeDirectory.path,
        memoryDirectory: memoryDirectory.path,
        personaConstitution: '测试人格宪法',
        browserLauncher: _RecordingBrowserLauncher(),
      );
      await expectLater(
        secondary.launch(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('loopback'),
          ),
        ),
      );

      await primary.close();
    },
  );
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
