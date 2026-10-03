@TestOn('browser')
library;

import 'dart:async';

import 'package:qiyu_flutter/features/chat/omni_call_usage_state_web.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

void main() {
  test('真实 tab 挂断标记在 reload 保留；关 tab 重开和 opener 复制均恢复', () async {
    final window = await _openTab();
    addTearDown(() => window.close());
    final initial = WebOmniCallUsageState(window);
    expect(initial.autoStartSuppressed, isFalse);
    initial.suppressAutoStart();
    expect(
      window.sessionStorage.getItem('qiyu_omni_auto_start_suppressed'),
      'true',
    );
    final previous = window.document;
    window.location.reload();
    await _waitFor(
      () =>
          window.document != previous &&
          window.document.readyState == 'complete',
    );
    expect(WebOmniCallUsageState(window).autoStartSuppressed, isTrue);

    // 新 tab 会复制 opener 的 sessionStorage，但是真正的新导航会清抑制。
    final copied = window.open(window.location.href, '_blank')!;
    addTearDown(() => copied.close());
    await _waitFor(
      () =>
          copied.location.href == window.location.href &&
          copied.document.readyState == 'complete',
    );
    expect(WebOmniCallUsageState(copied).autoStartSuppressed, isFalse);
    window.close();
    final reopened = await _openTab();
    addTearDown(() => reopened.close());
    expect(WebOmniCallUsageState(reopened).autoStartSuppressed, isFalse);
  });
}

Future<web.Window> _openTab() async {
  final url = Uri.base
      .resolve('/packages/qiyu_flutter/pubspec.yaml')
      .toString();
  final window = web.window.open(url, '_blank');
  expect(window, isNotNull, reason: 'browser runner 须允许创建真实 tab');
  await _waitFor(
    () =>
        window!.location.href == url &&
        window.document.readyState == 'complete',
  );
  return window!;
}

Future<void> _waitFor(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) fail('页面导航没有完成');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
