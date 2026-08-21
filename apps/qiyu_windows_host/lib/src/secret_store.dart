import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
import 'package:win32/win32.dart';

abstract interface class SecretStore {
  Future<String?> readApiKey(String scope);

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
    final value = _readTarget(_targetName(scope));
    if (value != null) {
      return value;
    }
    final legacyValue = _readTarget(_legacyTargetName(scope));
    if (legacyValue == null) {
      return null;
    }
    // 将按旧 FNV 命名保存的 Key 尽力迁移到 sha256 命名；迁移失败不影响本次读取。
    try {
      _writeTarget(_targetName(scope), legacyValue);
      _deleteTarget(_legacyTargetName(scope));
    } on SecretStoreException {
      // 忽略迁移失败。
    }
    return legacyValue;
  }

  @override
  Future<void> deleteApiKey(String scope) async {
    _requireWindows();
    _deleteTarget(_targetName(scope));
    _deleteTarget(_legacyTargetName(scope));
  }

  String? _readTarget(String targetName) {
    return using((arena) {
      final credentialPointer = arena<Pointer<CREDENTIAL>>();
      final target = arena.pcwstr(targetName);
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

  void _writeTarget(String targetName, String value) {
    using((arena) {
      final bytes = utf8.encode(value);
      final credential = arena<CREDENTIAL>();
      credential.ref
        ..Type = CRED_TYPE_GENERIC
        ..TargetName = arena.pwstr(targetName)
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

  void _deleteTarget(String targetName) {
    using((arena) {
      final result = CredDelete(arena.pcwstr(targetName), CRED_TYPE_GENERIC);
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

  String _legacyTargetName(String scope) =>
      '$targetNamePrefix.${_legacyScopeHash(scope)}';

  /// 旧 FNV 命名下的凭据 target 名，仅供迁移测试使用。
  @visibleForTesting
  String legacyTargetName(String scope) => _legacyTargetName(scope);
}

String _stableScopeHash(String value) =>
    sha256.convert(utf8.encode(value)).toString();

/// 旧的 FNV-1a 变体哈希，仅用于读取并迁移升级前保存的 Key。
String _legacyScopeHash(String value) {
  var hash = 0x4bf29ce484222325;
  for (final byte in utf8.encode(value)) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0x7FFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
