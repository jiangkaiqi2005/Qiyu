@TestOn('windows')
library;

import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';
import 'package:win32/win32.dart';

void main() {
  test('读取与删除不存在的凭据不报错', () async {
    final target =
        'Qiyu.Test.Provider.${DateTime.now().microsecondsSinceEpoch}';
    final store = WindowsCredentialSecretStore(targetNamePrefix: target);
    const scope = 'openai_compatible|https://example.com/v1';

    expect(await store.readApiKey(scope), isNull);
    expect(await store.readApiKey('anthropic|https://example.com/v1'), isNull);
    await store.deleteApiKey(scope);
    expect(await store.readApiKey(scope), isNull);
  });

  test('旧 FNV 命名下保存的 Key 会在读取时迁移到 sha256 命名', () async {
    final target =
        'Qiyu.Test.Provider.${DateTime.now().microsecondsSinceEpoch}';
    final store = WindowsCredentialSecretStore(targetNamePrefix: target);
    const scope = 'openai_compatible|https://legacy.example.com/v1';
    final legacyTarget = store.legacyTargetName(scope);
    addTearDown(() async {
      await store.deleteApiKey(scope);
      _deleteCredential(legacyTarget);
    });

    _writeCredential(legacyTarget, 'legacy-secret-value');

    expect(await store.readApiKey(scope), 'legacy-secret-value');
    expect(_readCredential(legacyTarget), isNull, reason: '旧命名凭据应被删除');
    expect(
      await store.readApiKey(scope),
      'legacy-secret-value',
      reason: '迁移后应能从新命名读到',
    );

    await store.deleteApiKey(scope);
    expect(await store.readApiKey(scope), isNull);
  });
}

void _writeCredential(String targetName, String value) {
  using((arena) {
    final bytes = utf8.encode(value);
    final credential = arena<CREDENTIAL>();
    credential.ref
      ..Type = CRED_TYPE_GENERIC
      ..TargetName = arena.pwstr(targetName)
      ..Persist = CRED_PERSIST_LOCAL_MACHINE
      ..UserName = arena.pwstr('Qiyu.Test')
      ..CredentialBlob = bytes.toNative(allocator: arena)
      ..CredentialBlobSize = bytes.length;
    final result = CredWrite(credential, 0);
    if (!result.value) {
      throw WindowsException(result.error.toHRESULT());
    }
  });
}

String? _readCredential(String targetName) {
  return using((arena) {
    final credentialPointer = arena<Pointer<CREDENTIAL>>();
    final result = CredRead(
      arena.pcwstr(targetName),
      CRED_TYPE_GENERIC,
      credentialPointer,
    );
    if (!result.value) {
      if (result.error == ERROR_NOT_FOUND) {
        return null;
      }
      throw WindowsException(result.error.toHRESULT());
    }
    try {
      final credential = credentialPointer.value.ref;
      return utf8.decode(
        credential.CredentialBlob.asTypedList(credential.CredentialBlobSize),
      );
    } finally {
      if (!credentialPointer.value.isNull) {
        CredFree(credentialPointer.value);
      }
    }
  });
}

void _deleteCredential(String targetName) {
  using((arena) {
    CredDelete(arena.pcwstr(targetName), CRED_TYPE_GENERIC);
  });
}
