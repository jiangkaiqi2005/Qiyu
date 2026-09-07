import 'host_api_gateway.dart';
import '../settings/provider_settings_client.dart'
    show ProviderSettingsGatewayException;

/// 后台最近失败的只读状态（ticket 21）：宿主记忆节奏模块的旁路记账
/// 快照，页面据此在壳层状态区展示一条安静提示。只含平实任务名、最近
/// 失败时刻、累计次数与是否已恢复，不含任何内部错误细节。
final class BackgroundFailureStatus {
  const BackgroundFailureStatus({
    required this.task,
    required this.failedAt,
    required this.count,
    required this.recovered,
  });

  /// 只读快照解码：宿主无失败时回 `task: null`（安静），解析为 null。
  static BackgroundFailureStatus? fromJson(Map<String, Object?> json) {
    final task = json['task'];
    if (task is! String || task.isEmpty) {
      return null;
    }
    return BackgroundFailureStatus(
      task: task,
      failedAt: DateTime.parse(json['failedAt']! as String),
      count: json['count']! as int,
      recovered: json['recovered']! as bool,
    );
  }

  /// 任务的平实中文名（日终归档/月压缩/梦境整理/恢复扫描/空闲补办）。
  final String task;

  /// 该条记录最近一次失败的时刻（本机时间）。
  final DateTime failedAt;

  /// 本条失败记录累计失败次数。
  final int count;

  /// 该任务失败之后是否已有一次成功（已恢复）。
  final bool recovered;

  @override
  bool operator ==(Object other) =>
      other is BackgroundFailureStatus &&
      other.task == task &&
      other.failedAt == failedAt &&
      other.count == count &&
      other.recovered == recovered;

  @override
  int get hashCode => Object.hash(task, failedAt, count, recovered);
}

/// 独立小接口：壳层的后台失败提示可单独注入与测试。
abstract interface class BackgroundStatusGateway {
  Future<BackgroundFailureStatus?> read();
}

final class HttpBackgroundStatusGateway extends HostApiGateway
    implements BackgroundStatusGateway {
  HttpBackgroundStatusGateway({super.client, super.baseUri});

  @override
  Object errorFor(String message) => ProviderSettingsGatewayException(message);

  @override
  String get unavailableMessage => '记忆整理状态暂时不可用。';

  @override
  Future<BackgroundFailureStatus?> read() =>
      getJson('/api/memory/cadence-status', BackgroundFailureStatus.fromJson);
}
