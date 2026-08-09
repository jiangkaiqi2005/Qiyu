import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

void main() {
  test('Windows host preflight verifies platform and behavior core wiring', () {
    final report = runHostPreflight(operatingSystem: 'windows');

    expect(report.ready, isTrue);
    expect(report.operatingSystem, 'windows');
    expect(report.checks, {'supportedPlatform': true, 'behaviorCore': true});
  });

  test('host preflight rejects unsupported development platforms', () {
    final report = runHostPreflight(operatingSystem: 'linux');

    expect(report.ready, isFalse);
    expect(report.checks['supportedPlatform'], isFalse);
    expect(report.checks['behaviorCore'], isTrue);
  });
}
