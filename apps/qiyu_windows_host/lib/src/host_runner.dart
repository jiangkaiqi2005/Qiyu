import 'dart:convert';
import 'dart:io';

import 'package:qiyu_local_host/qiyu_local_host.dart';

import 'secret_store.dart';
import 'single_instance.dart';

final class QiyuHostRunner {
  const QiyuHostRunner({
    required this.webRoot,
    required this.runtimeDirectory,
    required this.memoryDirectory,
    required this.personaConstitution,
    required this.browserLauncher,
  });

  final String webRoot;
  final String runtimeDirectory;
  final String memoryDirectory;
  final String personaConstitution;
  final BrowserLauncher browserLauncher;

  Future<HostLaunchResult> launch({bool openBrowser = true}) async {
    final lease = SingleInstanceLease.tryAcquire(runtimeDirectory);
    if (!lease.isPrimary) {
      final descriptor = await lease.readDescriptor();
      final activation = await _activateExisting(
        descriptor,
        activateBrowser: openBrowser,
      );
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
        personaConstitution: personaConstitution,
        activationToken: activationToken,
        // 平台凭据仓注入：Windows 凭据管理器实现留在本壳。
        secretStore: const WindowsCredentialSecretStore(),
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
    InstanceDescriptor descriptor, {
    required bool activateBrowser,
  }) async {
    // descriptor 可被本机同用户进程篡改，激活请求绝不发往 loopback 之外。
    if (!_isLoopbackOrigin(descriptor.origin)) {
      throw StateError('$existingInstanceFailurePrefix descriptor points outside loopback');
    }
    if (!activateBrowser) {
      return const _ActivationResult(
        browserLaunch: BrowserLaunchResult.skipped(),
      );
    }
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
      throw StateError('$existingInstanceFailurePrefix is not reachable');
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

bool _isLoopbackOrigin(Uri origin) {
  if (origin.host == 'localhost') {
    return true;
  }
  final address = InternetAddress.tryParse(origin.host);
  return address != null && address.isLoopback;
}
