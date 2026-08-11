import 'dart:convert';
import 'dart:io';

import 'browser_launcher.dart';
import 'local_app_host.dart';
import 'secure_token.dart';
import 'single_instance.dart';

final class QiyuHostRunner {
  const QiyuHostRunner({
    required this.webRoot,
    required this.runtimeDirectory,
    required this.memoryDirectory,
    required this.productSoul,
    required this.browserLauncher,
  });

  final String webRoot;
  final String runtimeDirectory;
  final String memoryDirectory;
  final String productSoul;
  final BrowserLauncher browserLauncher;

  Future<HostLaunchResult> launch({bool openBrowser = true}) async {
    final lease = SingleInstanceLease.tryAcquire(runtimeDirectory);
    if (!lease.isPrimary) {
      final descriptor = await lease.readDescriptor();
      final activation = await _activateExisting(descriptor);
      return HostLaunchResult._(
        isPrimary: false,
        origin: descriptor.origin,
        displayUri: activation.displayUri ?? descriptor.origin,
        browserLaunch: activation.browserLaunch,
        host: null,
        lease: lease,
      );
    }

    final activationToken = generateSecureToken();
    late LocalAppHost host;
    try {
      host = await LocalAppHost.start(
        webRoot: webRoot,
        memoryDirectory: memoryDirectory,
        productSoul: productSoul,
        activationToken: activationToken,
        onActivate: () => browserLauncher.open(host.launchUri),
      );
      lease.writeDescriptor(
        origin: host.origin,
        activationToken: activationToken,
      );
      final browserLaunch = openBrowser
          ? await browserLauncher.open(host.launchUri)
          : const BrowserLaunchResult.skipped();
      return HostLaunchResult._(
        isPrimary: true,
        origin: host.origin,
        displayUri: host.launchUri,
        browserLaunch: browserLaunch,
        host: host,
        lease: lease,
      );
    } catch (_) {
      await lease.close();
      rethrow;
    }
  }

  Future<_ActivationResult> _activateExisting(
    InstanceDescriptor descriptor,
  ) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        descriptor.origin.resolve('/_instance/activate'),
      );
      request.headers.set('x-qiyu-activation', descriptor.activationToken);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode == HttpStatus.noContent) {
        return const _ActivationResult(
          browserLaunch: BrowserLaunchResult(succeeded: true, error: null),
        );
      }
      Uri? displayUri;
      if (body.isNotEmpty) {
        final json = jsonDecode(body) as Map<String, Object?>;
        displayUri = Uri.tryParse(json['displayUrl'] as String? ?? '');
      }
      return _ActivationResult(
        browserLaunch: BrowserLaunchResult(
          succeeded: false,
          error: '已有栖语实例无法打开浏览器',
        ),
        displayUri: displayUri,
      );
    } on SocketException {
      throw StateError('Existing Qiyu instance is not reachable');
    } finally {
      client.close(force: true);
    }
  }
}

final class HostLaunchResult {
  HostLaunchResult._({
    required this.isPrimary,
    required this.origin,
    required this.displayUri,
    required this.browserLaunch,
    required this.host,
    required this._lease,
  });

  final bool isPrimary;
  final Uri origin;
  final Uri displayUri;
  final BrowserLaunchResult browserLaunch;
  final LocalAppHost? host;
  final SingleInstanceLease _lease;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await host?.close();
    await _lease.close();
  }
}

final class _ActivationResult {
  const _ActivationResult({required this.browserLaunch, this.displayUri});

  final BrowserLaunchResult browserLaunch;
  final Uri? displayUri;
}
