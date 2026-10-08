import 'dart:async';
import 'dart:typed_data';

import 'package:qiyu_local_host/src/embedding_gateway.dart';
import 'package:qiyu_local_host/src/provider_config.dart';

/// 静态 embedding 配置仓储：内存现值 + 事务直通（票 02/03 测试共用）。
final class StaticEmbeddingConfigRepository
    implements EmbeddingConfigRepository {
  StaticEmbeddingConfigRepository(this.config);

  EmbeddingConfig? config;

  @override
  Future<EmbeddingConfig?> loadEmbedding() async => config;

  @override
  Future<void> saveEmbedding(EmbeddingConfig config) async =>
      this.config = config;

  @override
  Future<T> runTransaction<T>(Future<T> Function() action) => action();
}

/// 脚本化 embedding 客户端：按输入映射向量，支持批响应脚本、失败注入
/// 与批闸门（维护竞态用例）。查询与构建请求的区分按「单条输入且不在
/// 构建向量表内」启发：测试把真实查询词写进 [queryVectors] 即可。
final class ScriptedEmbeddingClient implements EmbeddingClient {
  ScriptedEmbeddingClient({
    required this.vectors,
    this.queryVectors = const {},
    this.batchResponses,
    this.failures = const [],
    this.queryFailures = const [],
    this.batchGate,
  });

  /// 构建输入（日期+换行+摘要）到向量的映射。
  final Map<String, List<double>> vectors;

  /// 查询词到向量的映射；缺省回退 [1.0, 0.0]。
  final Map<String, List<double>> queryVectors;

  /// 按调用次序消费的批响应脚本（跨批维度不一致等场景）。
  final List<List<List<double>>>? batchResponses;

  /// 构建请求按次序抛出的失败。
  final List<EmbeddingGatewayException> failures;

  /// 查询请求按次序抛出的失败。
  final List<EmbeddingGatewayException> queryFailures;

  /// 构建请求在响应前等待的闸门（维护竞态用例）。
  final Completer<void>? batchGate;

  /// 查询请求在响应前等待的闸门（实时迟到结果用例，票 07）；置位后
  /// 查询在网关上等待放行。[queryEntered] 在首次入闸时完成，供测试
  /// 确定性等待「查询已在途」。
  Completer<void>? queryGate;
  final Completer<void> queryEntered = Completer<void>();

  final List<List<String>> calls = [];

  @override
  Future<List<Float32List>> embed({
    required EmbeddingConfig config,
    required String? apiKey,
    required List<String> inputs,
    Duration? timeout,
  }) async {
    calls.add(inputs);
    final isQuery = inputs.length == 1 && !vectors.containsKey(inputs.single);
    if (batchGate != null && !isQuery) {
      await batchGate!.future;
    }
    if (isQuery && queryGate != null) {
      if (!queryEntered.isCompleted) {
        queryEntered.complete();
      }
      await queryGate!.future;
    }
    if (isQuery && queryFailures.isNotEmpty) {
      throw queryFailures.removeAt(0);
    }
    if (!isQuery && failures.isNotEmpty) {
      throw failures.removeAt(0);
    }
    if (batchResponses case final responses? when responses.isNotEmpty) {
      return [
        for (final vector in responses.removeAt(0))
          Float32List.fromList(vector),
      ];
    }
    return [
      for (final input in inputs)
        Float32List.fromList(
          (isQuery ? queryVectors[input] : vectors[input]) ??
              const [1.0, 0.0],
        ),
    ];
  }
}

/// 可控闸门包装（票 04）：批请求（非查询）可暂停在网关上，用于观察
/// 「更新中」状态与制造在途竞争；查询请求永不入闸。[entered] 在首次
/// 入闸时完成，供测试确定性等待「请求已在途」。
final class GatedEmbeddingClient implements EmbeddingClient {
  GatedEmbeddingClient(this.inner);

  final ScriptedEmbeddingClient inner;

  /// 置位后批请求在响应前等待；null 直通。
  Completer<void>? gate;

  final Completer<void> entered = Completer<void>();

  List<List<String>> get calls => inner.calls;
  Map<String, List<double>> get vectors => inner.vectors;
  List<EmbeddingGatewayException> get failures => inner.failures;

  @override
  Future<List<Float32List>> embed({
    required EmbeddingConfig config,
    required String? apiKey,
    required List<String> inputs,
    Duration? timeout,
  }) async {
    final isQuery =
        inputs.length == 1 && !inner.vectors.containsKey(inputs.single);
    if (gate != null && !isQuery) {
      if (!entered.isCompleted) {
        entered.complete();
      }
      await gate!.future;
    }
    return inner.embed(
      config: config,
      apiKey: apiKey,
      inputs: inputs,
      timeout: timeout,
    );
  }
}
