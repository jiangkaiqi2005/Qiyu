import 'package:qiyu_local_host/qiyu_local_host.dart';

/// 记录型 HTTP 客户端：转写/合成网关用例共用。把每次 post 的 uri、头、
/// 请求体字节与超时预算逐字段留档（请求形状逐字段比对用），并按构造入参
/// 返回固定响应或抛固定异常（错误分类用例用）。[response] 与 [error] 都
/// 不给时未使用的调用点不会触达。
final class RecordingHttpClient implements ProviderHttpClient {
  RecordingHttpClient({this.response, this.error});

  final ProviderHttpResponse? response;
  final Object? error;
  bool called = false;
  late Duration timeout;
  ProviderResponseBudget? budget;
  Future<void>? whenCancelled;
  late Uri uri;
  late Map<String, String> headers;
  late List<int> bytesBody;

  @override
  Future<ProviderHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
    Future<void>? whenCancelled,
    ProviderResponseBudget? budget,
  }) async {
    called = true;
    this.timeout = timeout;
    this.budget = budget;
    this.whenCancelled = whenCancelled;
    this.uri = uri;
    this.headers = headers;
    bytesBody = body;
    if (error case final failure?) {
      throw failure;
    }
    return response!;
  }
}
