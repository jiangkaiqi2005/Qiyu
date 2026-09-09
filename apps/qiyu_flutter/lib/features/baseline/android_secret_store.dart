import 'package:flutter/services.dart';
import 'package:qiyu_local_host/qiyu_local_host.dart';

/// Android 凭据仓的平台通道名（原生侧 MainActivity.kt 注册同名处理器）。
const androidSecureStoreChannelName = 'dev.qiyu.app/secure_store';

/// Android 凭据仓：经平台通道调用原生壳里的 AndroidKeyStore 支撑的
/// 系统安全存储（AES-256/GCM 密钥入 AndroidKeyStore 不可导出，密文
/// 与独立 IV 落应用私有 SharedPreferences，条目按 scope 一一对应）。
///
/// 接口语义与 Windows 凭据管理器实现对齐：读取返回 null 表示无条目，
/// 删除对不存在的条目幂等成功；任何存储失败转 [SecretStoreException]
/// （固定人话文案，绝不携带 scope 或 Key 内容）。
///
/// [writeApiKey] 是通道三方法中的 set：SecretStore 接口本身只有读取
/// 与删除（Host 现行 Key 主存是 provider.json，凭据仓承担迁移回退与
/// 旧值清理），set 随通道协议完整就位，Host 将 Key 主存迁入凭据仓
/// 时可直接使用，无需再动原生协议。
final class AndroidSecretStore implements SecretStore {
  const AndroidSecretStore();

  static const MethodChannel _channel = MethodChannel(
    androidSecureStoreChannelName,
  );

  @override
  Future<String?> readApiKey(String scope) =>
      _invoke('get', {'scope': scope}, '无法读取本机安全存储中的 API Key。');

  Future<void> writeApiKey(String scope, String value) => _invoke(
    'set',
    {'scope': scope, 'value': value},
    '无法安全保存 API Key。',
  );

  @override
  Future<void> deleteApiKey(String scope) =>
      _invoke('delete', {'scope': scope}, '无法删除本机安全存储中的 API Key。');

  /// 通道调用与错误翻译的唯一出口：原生错误与「无原生处理器」统一转
  /// [SecretStoreException]，原异常入 cause 供诊断，对外文案固定。
  Future<T?> _invoke<T>(
    String method,
    Map<String, Object?> arguments,
    String failureMessage,
  ) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw SecretStoreException(failureMessage, error);
    } on MissingPluginException catch (error) {
      throw SecretStoreException('本机安全存储在此环境不可用。', error);
    }
  }
}
