@TestOn('windows')
library;

import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

void main() {
  test('API Key 通过 Windows Credential Manager 持久保存和删除', () async {
    final target =
        'Qiyu.Test.Provider.${DateTime.now().microsecondsSinceEpoch}';
    final store = WindowsCredentialSecretStore(targetName: target);
    addTearDown(store.deleteApiKey);

    expect(await store.readApiKey(), isNull);
    await store.writeApiKey('test-only-secret-value');
    expect(await store.readApiKey(), 'test-only-secret-value');
    await store.deleteApiKey();
    expect(await store.readApiKey(), isNull);
  });
}
