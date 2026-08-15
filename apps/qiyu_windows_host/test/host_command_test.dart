import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

void main() {
  test('parses check, browser, Web root, and runtime directory options', () {
    final options = HostCommandOptions.parse([
      '--check',
      '--no-browser',
      '--web-root',
      r'C:\Qiyu\web',
      '--runtime-dir',
      r'C:\Qiyu\runtime',
      '--memory-dir',
      r'C:\Qiyu\memories',
    ]);

    expect(options.checkOnly, isTrue);
    expect(options.openBrowser, isFalse);
    expect(options.webRoot, r'C:\Qiyu\web');
    expect(options.runtimeDirectory, r'C:\Qiyu\runtime');
    expect(options.memoryDirectory, r'C:\Qiyu\memories');
  });

  test(
    'resolves memory directory from override, environment, then user profile',
    () {
      expect(
        resolveHostMemoryDirectory(
          environment: const {'USERPROFILE': r'C:\Users\qiyu'},
          overridePath: r'D:\QiyuData',
        ),
        path.normalize(path.absolute(r'D:\QiyuData')),
      );
      expect(
        resolveHostMemoryDirectory(
          environment: const {
            'QIYU_MEMORY_DIR': r'D:\Configured',
            'USERPROFILE': r'C:\Users\qiyu',
          },
        ),
        path.normalize(path.absolute(r'D:\Configured')),
      );
      expect(
        resolveHostMemoryDirectory(
          environment: const {'USERPROFILE': r'C:\Users\qiyu'},
        ),
        path.join(r'C:\Users\qiyu', '.qiyu', 'memories'),
      );
    },
  );

  test('resolves the Flutter Web build next to the host project', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-command-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final hostDirectory = Directory(
      path.join(temporaryDirectory.path, 'apps', 'qiyu_windows_host'),
    )..createSync(recursive: true);
    final webDirectory = Directory(
      path.join(
        temporaryDirectory.path,
        'apps',
        'qiyu_flutter',
        'build',
        'web',
      ),
    )..createSync(recursive: true);
    File(
      path.join(webDirectory.path, 'index.html'),
    ).writeAsStringSync('<!doctype html>');
    final resolved = resolveHostWebRoot(
      currentDirectory: hostDirectory.path,
      executablePath: path.join(hostDirectory.path, 'host.exe'),
    );

    expect(path.equals(resolved, webDirectory.path), isTrue);
  });

  test('resolves bundled Web assets beside a movable executable', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-bundle-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final bundleDirectory = Directory(
      path.join(temporaryDirectory.path, 'windows-bundle'),
    )..createSync();
    final webDirectory = Directory(path.join(bundleDirectory.path, 'web'))
      ..createSync();
    File(
      path.join(webDirectory.path, 'index.html'),
    ).writeAsStringSync('<!doctype html>');
    final personaConstitution = File(
      path.join(bundleDirectory.path, 'persona-constitution.md'),
    )..writeAsStringSync('测试人格宪法');

    final resolved = resolveHostWebRoot(
      currentDirectory: temporaryDirectory.path,
      executablePath: path.join(bundleDirectory.path, 'qiyu_windows_host.exe'),
    );

    expect(path.equals(resolved, webDirectory.path), isTrue);
    expect(
      path.equals(
        resolvePersonaConstitutionPath(
          currentDirectory: temporaryDirectory.path,
          executablePath: path.join(
            bundleDirectory.path,
            'qiyu_windows_host.exe',
          ),
        ),
        personaConstitution.path,
      ),
      isTrue,
    );
  });

  test('preflight includes bundled Web assets when a root is supplied', () {
    final webRoot = Directory.systemTemp.createTempSync('qiyu-preflight-test-');
    addTearDown(() => webRoot.deleteSync(recursive: true));
    File(
      path.join(webRoot.path, 'index.html'),
    ).writeAsStringSync('<!doctype html>');

    final report = runHostPreflight(
      operatingSystem: 'windows',
      webRoot: webRoot.path,
    );

    expect(report.ready, isTrue);
    expect(report.checks['webAssets'], isTrue);
  });
}
