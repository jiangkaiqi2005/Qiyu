import 'dart:io';

import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

void main() {
  group('启动失败原因映射', () {
    test('Web 页面资源缺失映射为重新解压指引，且不透出本机路径', () {
      final failure = classifyStartupFailure(
        FileSystemException(
          webAssetsMissingFailureMessage,
          r'C:\Users\someone\AppData\Local\Qiyu\web',
        ),
      );

      expect(failure.reason, StartupFailureReason.webAssetsMissing);
      expect(failure.userMessage, contains('重新解压'));
      expect(failure.userMessage, isNot(contains(r'C:\')));
    });

    test('人格宪法文件缺失映射为重新解压指引', () {
      final failure = classifyStartupFailure(
        FileSystemException(personaConstitutionMissingFailureMessage),
      );

      expect(failure.reason, StartupFailureReason.constitutionMissing);
      expect(failure.userMessage, contains('重新解压'));
    });

    test('宿主校验 Web 根目录失败同样映射为资源缺失', () {
      final failure = classifyStartupFailure(
        ArgumentError.value('缺失目录', 'webRoot', 'index.html not found'),
      );

      expect(failure.reason, StartupFailureReason.webAssetsMissing);
    });

    test('找不到用户目录映射为记忆存放位置说明', () {
      final failure = classifyStartupFailure(
        StateError(userDirectoryMissingFailureMessage),
      );

      expect(failure.reason, StartupFailureReason.memoryDirectoryUnavailable);
      expect(failure.userMessage, contains('记忆'));
    });

    test('已有实例的三种异常都映射为实例冲突指引', () {
      for (final message in [
        '$existingInstanceFailurePrefix descriptor points outside loopback',
        '$existingInstanceFailurePrefix is not reachable',
        '$existingInstanceFailurePrefix did not publish its address',
      ]) {
        final failure = classifyStartupFailure(StateError(message));

        expect(failure.reason, StartupFailureReason.instanceConflict,
            reason: message);
        expect(failure.userMessage, contains('已经在运行'));
      }
    });

    test('未知异常归入未预期并指向启动日志，不带异常原文', () {
      final failure = classifyStartupFailure(
        Exception('第三方原始错误 with C:\\secret\\path'),
      );

      expect(failure.reason, StartupFailureReason.unexpected);
      expect(failure.userMessage, contains('启动日志'));
      expect(failure.userMessage, isNot(contains('第三方')));
      expect(failure.userMessage, isNot(contains(r'C:\')));
    });
  });

  group('启动自检失败映射', () {
    test('按平台、行为核心、Web 资源的顺序取首要原因', () {
      expect(
        classifyPreflightChecks({
          'supportedPlatform': false,
          'behaviorCore': false,
          'webAssets': false,
        }).reason,
        StartupFailureReason.unsupportedPlatform,
      );
      expect(
        classifyPreflightChecks({
          'supportedPlatform': true,
          'behaviorCore': false,
          'webAssets': false,
        }).reason,
        StartupFailureReason.selfCheckFailed,
      );
      expect(
        classifyPreflightChecks({
          'supportedPlatform': true,
          'behaviorCore': true,
          'webAssets': false,
        }).reason,
        StartupFailureReason.webAssetsMissing,
      );
    });
  });

  group('启动失败呈现', () {
    late Directory temporaryDirectory;

    setUp(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'qiyu-startup-failure-test-',
      );
    });

    tearDown(() async {
      if (temporaryDirectory.existsSync()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });

    File logFile() => File(
          '${temporaryDirectory.path}${Platform.pathSeparator}'
          '${StartupFailureReporter.logFileName}',
        );

    test('弹窗与运行目录日志拿到同一份人话原因', () {
      final presenter = _FakeStartupFailurePresenter();
      final reporter = StartupFailureReporter(
        presenter: presenter,
        logDirectoryPath: temporaryDirectory.path,
      );

      reporter.reportError(
        FileSystemException(webAssetsMissingFailureMessage),
      );

      expect(presenter.presented, hasLength(1));
      expect(
        presenter.presented.single.reason,
        StartupFailureReason.webAssetsMissing,
      );
      final log = logFile().readAsStringSync();
      expect(log, contains(presenter.presented.single.userMessage));
      expect(log, contains('webAssetsMissing'));
    });

    test('自检报告经呈现器落到弹窗与日志', () {
      final presenter = _FakeStartupFailurePresenter();
      final reporter = StartupFailureReporter(
        presenter: presenter,
        logDirectoryPath: temporaryDirectory.path,
      );

      reporter.reportPreflightChecks({
        'supportedPlatform': true,
        'behaviorCore': true,
        'webAssets': false,
      });

      expect(presenter.presented.single.reason,
          StartupFailureReason.webAssetsMissing);
      expect(logFile().readAsStringSync(),
          contains(presenter.presented.single.userMessage));
    });

    test('运行目录不存在时先建目录再写日志', () {
      final nested = Directory(
        '${temporaryDirectory.path}${Platform.pathSeparator}runtime',
      );
      final reporter = StartupFailureReporter(
        presenter: _FakeStartupFailurePresenter(),
        logDirectoryPath: nested.path,
      );

      reporter.report(const StartupFailure(StartupFailureReason.unexpected));

      expect(
        File(
          '${nested.path}${Platform.pathSeparator}'
          '${StartupFailureReporter.logFileName}',
        ).existsSync(),
        isTrue,
      );
    });

    test('日志按次追加，保留历史失败记录', () {
      final reporter = StartupFailureReporter(
        presenter: _FakeStartupFailurePresenter(),
        logDirectoryPath: temporaryDirectory.path,
      );

      reporter.report(
        const StartupFailure(StartupFailureReason.webAssetsMissing),
      );
      reporter.report(
        const StartupFailure(StartupFailureReason.instanceConflict),
      );

      final log = logFile().readAsStringSync();
      expect(log.split('\n').where((line) => line.isNotEmpty), hasLength(2));
      expect(log, contains('webAssetsMissing'));
      expect(log, contains('instanceConflict'));
    });

    test('日志写不进去时安静放弃，弹窗照常呈现', () {
      // 用一个文件路径当目录，写入必然失败，且 Windows 与 Linux 行为一致。
      final blocker = File(
        '${temporaryDirectory.path}${Platform.pathSeparator}not-a-directory',
      )..writeAsStringSync('');
      final presenter = _FakeStartupFailurePresenter();
      final reporter = StartupFailureReporter(
        presenter: presenter,
        logDirectoryPath: '${blocker.path}${Platform.pathSeparator}runtime',
      );

      reporter.reportError(
        FileSystemException(webAssetsMissingFailureMessage),
      );

      expect(presenter.presented, hasLength(1));
      expect(
        presenter.presented.single.reason,
        StartupFailureReason.webAssetsMissing,
      );
    });
  });
}

final class _FakeStartupFailurePresenter implements StartupFailurePresenter {
  final List<StartupFailure> presented = [];

  @override
  void present(StartupFailure failure) {
    presented.add(failure);
  }
}
