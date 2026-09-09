/// 凭据仓抽象接口：API Key 的本机安全存取。
///
/// 接口定义在平台无关包，平台壳注入各自实现（Windows 凭据管理器、
/// Android Keystore 支撑的安全存储等）；Host 纯 Dart 包不碰任何
/// 平台插件。读取设置永不返回明文 Key 的不变量由各服务层维持。
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

