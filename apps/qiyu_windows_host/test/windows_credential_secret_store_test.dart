@TestOn('windows')
library;

import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

void main() {
  test('API Key 通过 Windows Credential Manager 持久保存和删除', () async {
    final target =
        'Qiyu.Test.Provider.${DateTime.now().microsecondsSinceEpoch}';
    final store = WindowsCredentialSecretStore(targetNamePrefix: target);
    const scope = 'openai_compatible|https://example.com/v1';
    addTearDown(() => store.deleteApiKey(scope));

    expect(await store.readApiKey(scope), isNull);
    await store.writeApiKey(scope, 'test-only-secret-value');
    expect(await store.readApiKey(scope), 'test-only-secret-value');
    expect(await store.readApiKey('anthropic|https://example.com/v1'), isNull);
    await store.deleteApiKey(scope);
    expect(await store.readApiKey(scope), isNull);
  });
}
