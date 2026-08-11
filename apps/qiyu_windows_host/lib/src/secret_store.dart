import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

abstract interface class SecretStore {
  Future<String?> readApiKey(String scope);

  Future<void> writeApiKey(String scope, String value);

  Future<void> deleteApiKey(String scope);
}

final class SecretStoreException implements Exception {
  const SecretStoreException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

final class WindowsCredentialSecretStore implements SecretStore {
  const WindowsCredentialSecretStore({
    this.targetNamePrefix = 'Qiyu.Provider.ApiKey',
  });

  final String targetNamePrefix;

  @override
  Future<String?> readApiKey(String scope) async {
    _requireWindows();
    return using((arena) {
      final credentialPointer = arena<Pointer<CREDENTIAL>>();
      final target = arena.pcwstr(_targetName(scope));
      try {
        final result = CredRead(target, CRED_TYPE_GENERIC, credentialPointer);
        if (!result.value) {
          if (result.error == ERROR_NOT_FOUND) {
            return null;
          }
          throw WindowsException(result.error.toHRESULT());
        }
        final credential = credentialPointer.value.ref;
        final bytes = credential.CredentialBlob.asTypedList(
          credential.CredentialBlobSize,
        );
        return utf8.decode(bytes);
      } on Object catch (error) {
        if (error is WindowsException &&
            error.hr == ERROR_NOT_FOUND.toHRESULT()) {
          return null;
        }
        throw SecretStoreException('无法读取本机保存的 API Key。', error);
      } finally {
        if (!credentialPointer.value.isNull) {
          CredFree(credentialPointer.value);
        }
      }
    });
  }

  @override
  Future<void> writeApiKey(String scope, String value) async {
    _requireWindows();
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw const SecretStoreException('API Key 不能为空。');
    }
    using((arena) {
      final bytes = utf8.encode(trimmed);
      final credential = arena<CREDENTIAL>();
      credential.ref
        ..Type = CRED_TYPE_GENERIC
        ..TargetName = arena.pwstr(_targetName(scope))
        ..Persist = CRED_PERSIST_LOCAL_MACHINE
        ..UserName = arena.pwstr('Qiyu')
        ..CredentialBlob = bytes.toNative(allocator: arena)
        ..CredentialBlobSize = bytes.length;
      final result = CredWrite(credential, 0);
      if (!result.value) {
        throw SecretStoreException(
          '无法安全保存 API Key。',
          WindowsException(result.error.toHRESULT()),
        );
      }
    });
  }

  @override
  Future<void> deleteApiKey(String scope) async {
    _requireWindows();
    using((arena) {
      final result = CredDelete(
        arena.pcwstr(_targetName(scope)),
        CRED_TYPE_GENERIC,
      );
      if (!result.value && result.error != ERROR_NOT_FOUND) {
        throw SecretStoreException(
          '无法删除本机保存的 API Key。',
          WindowsException(result.error.toHRESULT()),
        );
      }
    });
  }

  void _requireWindows() {
    if (!Platform.isWindows) {
      throw const SecretStoreException('Windows 凭据存储只可在 Windows 使用。');
    }
  }

  String _targetName(String scope) =>
      '$targetNamePrefix.${_stableScopeHash(scope)}';
}

String _stableScopeHash(String value) {
  var hash = 0x4bf29ce484222325;
  for (final byte in utf8.encode(value)) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0x7FFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
