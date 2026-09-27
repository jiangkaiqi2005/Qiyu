import 'dart:convert';
import 'dart:io';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:qiyu_windows_host/src/single_instance.dart';
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

  // 壳编排测试共用装配：五个参数里只有 browserLauncher（个别用例连
  // webRoot）有差异，构造形状在此收拢一次。
  QiyuHostRunner buildRunner(
    BrowserLauncher browserLauncher, {
    String? webRootPath,
  }) =>
      QiyuHostRunner(
        webRoot: webRootPath ?? webRoot.path,
        runtimeDirectory: runtimeDirectory.path,
        memoryDirectory: memoryDirectory.path,
        personaConstitution: '测试人格宪法',
        browserLauncher: browserLauncher,
      );

  test(
    'a second launch activates the existing host instead of starting another',
    () async {
      final primaryBrowser = _RecordingBrowserLauncher();
      final primary = await buildRunner(primaryBrowser).launch();

      expect(primary.isPrimary, isTrue);
      expect(primary.host, isNotNull);
      expect(primaryBrowser.openedUris, [primary.displayUri]);

      final secondaryBrowser = _RecordingBrowserLauncher();
      final secondary = await buildRunner(secondaryBrowser).launch();

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
    final launch = await buildRunner(browser).launch();

    expect(launch.isPrimary, isTrue);
    expect(launch.browserLaunch.succeeded, isFalse);
    expect(launch.displayUri.host, InternetAddress.loopbackIPv4.address);
    expect(launch.displayUri.queryParameters['token'], isNotEmpty);

    await launch.close();
  });

  test('no-browser launch keeps single-instance activation headless', () async {
    final primaryBrowser = _RecordingBrowserLauncher();
    final primary = await buildRunner(
      primaryBrowser,
    ).launch(openBrowser: false);
    HostLaunchResult? secondary;
    HostLaunchResult? interactive;
    try {
      secondary = await buildRunner(
        _RecordingBrowserLauncher(),
      ).launch(openBrowser: false);

      expect(secondary.isPrimary, isFalse);
      expect(primaryBrowser.openedUris, isEmpty);

      interactive = await buildRunner(_RecordingBrowserLauncher()).launch();
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
      final primary = await buildRunner(_RecordingBrowserLauncher()).launch();
      expect(primary.isPrimary, isTrue);

      final descriptorFile = File(
        '${runtimeDirectory.path}${Platform.pathSeparator}instance.json',
      );
      final json =
          jsonDecode(descriptorFile.readAsStringSync())
              as Map<String, Object?>;
      json['origin'] = 'http://evil.example:8080';
      descriptorFile.writeAsStringSync(jsonEncode(json));

      final secondary = buildRunner(_RecordingBrowserLauncher());
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

  test('a failed primary launch releases the single-instance lock', () async {
    final failing = buildRunner(
      _RecordingBrowserLauncher(),
      webRootPath:
          '${temporaryDirectory.path}${Platform.pathSeparator}missing-web',
    );
    await expectLater(failing.launch(), throwsA(isA<ArgumentError>()));

    // 启动失败必须释放文件锁，否则同一 runtime 目录永远无法再启动。
    final retry = await buildRunner(_RecordingBrowserLauncher()).launch();
    expect(retry.isPrimary, isTrue);

    await retry.close();
  });

  test(
    'activating a primary whose browser fails hands back its login URL',
    () async {
      final primary = await buildRunner(
        _RecordingBrowserLauncher(succeeds: false),
      ).launch();
      expect(primary.isPrimary, isTrue);

      final secondary = await buildRunner(_RecordingBrowserLauncher()).launch();

      expect(secondary.isPrimary, isFalse);
      expect(secondary.browserLaunch.succeeded, isFalse);
      expect(secondary.browserLaunch.error, '已有栖语实例无法打开浏览器');
      expect(secondary.displayUri, primary.displayUri);

      await secondary.close();
      await primary.close();
    },
  );

  test(
    'an unreachable existing instance fails activation instead of starting another',
    () async {
      // 模拟持有锁但已死的实例：先占用锁并写下指向空闲端口的描述文件。
      final lease = SingleInstanceLease.tryAcquire(runtimeDirectory.path);
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = server.port;
      await server.close();
      lease.writeDescriptor(
        origin: Uri.parse('http://127.0.0.1:$deadPort'),
        activationToken: 'stale-activation-token',
      );

      final secondary = buildRunner(_RecordingBrowserLauncher());
      try {
        await expectLater(
          secondary.launch(),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('not reachable'),
            ),
          ),
        );
      } finally {
        await lease.close();
      }
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
