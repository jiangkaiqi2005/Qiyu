import 'dart:async';

import 'embedding_gateway.dart';
import 'episode_index.dart';
import 'episode_memory.dart';
import 'episode_rag_index.dart';
import 'markdown_memory_repository.dart'
    show AtomicTextWriter, redactSessionText, stderrDiagnostics;
import 'memory_text_primitives.dart';
import 'model_gateway.dart' show ModelFailureKind;
import 'open_loop_store.dart';
import 'provider_config.dart';

/// 后台构建的批次上限与批次预算（Spec 表「后台构建」）：每批最多 10
/// 条、每批 30 秒——与查询时限（10 秒）分开，批量请求允许更慢。
const episodeRagBatchSize = 10;
const episodeRagBatchTimeout = Duration(seconds: 30);

/// 查询取回的当前有效候选上限（Spec 表「排名」）：精确余弦最多 10 条。
const episodeRagQueryLimit = 10;

/// 召回状态的六个展示口径里，本票先落地五个（「更新中」随增量同步在
/// 后续票引入）：未启用、准备中、已就绪、需重建、暂不可用。
enum EpisodeRagState {
  disabled('disabled'),
  preparing('preparing'),
  ready('ready'),
  rebuildNeeded('rebuildNeeded'),
  unavailable('unavailable');

  const EpisodeRagState(this.wireName);

  final String wireName;
}

/// 召回状态快照：经 HTTP 返回时只含状态名、进度与人话原因，不含地址
/// 以外的服务细节，绝不携带 Key。
final class EpisodeRagStatus {
  const EpisodeRagStatus({
    required this.state,
    this.progressDone = 0,
    this.progressTotal = 0,
    this.reason,
  });

  final EpisodeRagState state;

  /// 准备中的完成量（已完成条目数 / 总条目数）；其余状态为 0。
  final int progressDone;
  final int progressTotal;

  /// 暂不可用或需重建的简短人话原因；其余状态为 null。
  final String? reason;

  Map<String, Object?> toJson() => {
    'state': state.wireName,
    'progressDone': progressDone,
    'progressTotal': progressTotal,
    if (reason != null) 'reason': reason,
  };
}

/// 一次 RAG 定位的三态结果（Spec：未启用走旧路径；已启用但不可用明确
/// 展示，不静默回退；就绪时返回当前有效的候选材料）。
sealed class EpisodeRagLocateResult {
  const EpisodeRagLocateResult();
}

/// 未启用 RAG：调用方继续走既有目录召回。
final class RagNotEnabled extends EpisodeRagLocateResult {
  const RagNotEnabled();
}

/// 已启用但当前不可用（准备中、需重建或查询失败）：不回退旧路径，
/// 也不冒充没有候选；诊断进本机 sink，状态由设置与聊天界面展示。
final class RagUnavailable extends EpisodeRagLocateResult {
  const RagUnavailable(this.diagnostic);

  final String diagnostic;
}

/// 就绪查询的结果：命中条目已按当前来源回读并校验（存在、有效、控制、
/// 来源 hash），再按会话脱敏规则过滤；空列表就是没有有效候选。
final class RagCandidates extends EpisodeRagLocateResult {
  const RagCandidates(this.hits, {this.diagnostics = const []});

  final List<EpisodeRagHit> hits;
  final List<String> diagnostics;
}

/// 一条命中的候选：日期、当前有效条目（已脱敏）与建索引时的输入
/// hash（下一轮消费复验用）。原话摘录不在 embedding 输入里，只随
/// 条目回读供组织调用使用。
final class EpisodeRagHit {
  const EpisodeRagHit({
    required this.date,
    required this.entry,
    required this.inputSha256,
  });

  final String date;
  final EpisodeEntry entry;
  final String inputSha256;
}

/// Episode RAG 服务（Spec「配置、凭据与操作契约」+「来源有效性、同步
/// 与维护」）：启用/停用/重建的显式操作、后台完整构建、状态机与向量
/// 查询。组合根创建一个实例，轮内召回（文字）与实时查找共用同一份
/// 定位结果。
///
/// 状态只存内存：持久化事实只有 provider.json 的启用位与 NDJSON 索引
/// 文件。重启后按「启用位 + 当前缓存身份」重新落到就绪或需重建——
/// 准备中与失败不跨进程伪装成已就绪。
final class EpisodeRagService {
  EpisodeRagService({
    required this.memoryDirectory,
    required this.configRepository,
    required this.embeddingClient,
    required this.episodePipeline,
    this.openLoopStore,
    void Function(String message)? diagnosticsSink,
    AtomicTextWriter? atomicWriter,
  }) : diagnosticsSink = diagnosticsSink ?? stderrDiagnostics,
       _indexStore = EpisodeRagIndexStore(
         memoryDirectory: memoryDirectory,
         commits: episodePipeline.commits,
         atomicWriter: atomicWriter,
       );

  final String memoryDirectory;
  final EmbeddingConfigRepository configRepository;
  final EmbeddingClient embeddingClient;
  final EpisodeMemoryPipeline episodePipeline;

  /// 记忆控制（禁提 ∪ 删除 ∪ 冻结）的只读来源：null 时按空受控集合
  /// 处理（与轮内召回的 [RecallOrchestrator] 同律）。
  final OpenLoopStore? openLoopStore;
  final void Function(String message) diagnosticsSink;

  final EpisodeRagIndexStore _indexStore;

  EpisodeRagState _state = EpisodeRagState.disabled;
  String? _reason;
  int _progressDone = 0;
  int _progressTotal = 0;

  /// 已加载的缓存索引：就绪状态的查询与身份核对都基于它。加载失败或
  /// 身份失配时为 null（需重建）。
  EpisodeRagIndex? _loadedIndex;

  /// 启用位的内存镜像：构建循环据此在批次边界发现「构建中被停用」。
  bool _enabled = false;

  /// 后台构建任务链：同一时刻至多一个构建在推进；维护入口经
  /// [settlePendingWork] 排空。
  Future<void> _buildTask = Future.value();

  /// 维护代数：构建开始时记账，发布前重对——导入/回滚/清除完成后
  /// 代数推进，在途构建不得把旧来源的结果发布出去（Spec 决策 7）。
  int _maintenanceGeneration = 0;

  /// 维护暂停位：置位期间不启动新构建（已入链的构建开头自查让路）。
  bool _paused = false;

  /// 当前状态快照：先与持久化事实对齐（启用位、缓存身份），再返回。
  Future<EpisodeRagStatus> status() async {
    await _syncState();
    return EpisodeRagStatus(
      state: _state,
      progressDone: _progressDone,
      progressTotal: _progressTotal,
      reason: _reason,
    );
  }

  /// 显式启用（Spec：保存配置与启用分开）：写入启用位；缓存可用则
  /// 直接就绪（同身份换 Key、停用后再启用都不重算），否则触发后台
  /// 完整构建。未配置服务不能启用。
  Future<EpisodeRagStatus> enable() async {
    await configRepository.runTransaction(() async {
      final config = await configRepository.loadEmbedding();
      if (config == null) {
        throw const ProviderConfigException('还没有保存记忆召回服务配置，无法启用。');
      }
      await configRepository.saveEmbedding(config.withEnabled(true));
    });
    await _syncState(forceReload: true);
    if (_state == EpisodeRagState.disabled ||
        _state == EpisodeRagState.rebuildNeeded) {
      _scheduleBuild();
      // 构建已入链：立即如实反映「准备中」，进度随构建推进。
      _state = EpisodeRagState.preparing;
      _reason = null;
    }
    return status();
  }

  /// 显式停用（Spec：明确停用后返回旧路径）：清除启用位，召回立即走
  /// 旧目录；在途构建在批次边界发现停用后放弃，不发布。缓存文件保留，
  /// 重新启用时同身份可直接就绪。
  Future<EpisodeRagStatus> disable() async {
    await configRepository.runTransaction(() async {
      final config = await configRepository.loadEmbedding();
      if (config != null) {
        await configRepository.saveEmbedding(config.withEnabled(false));
      }
    });
    _enabled = false;
    _state = EpisodeRagState.disabled;
    _reason = null;
    _progressDone = 0;
    _progressTotal = 0;
    return status();
  }

  /// 明确重建/重试（Spec：需重建与暂不可用都提供明确重试入口）：按
  /// 当前配置完整重建。未启用时重建是无效操作。
  Future<EpisodeRagStatus> rebuild() async {
    await _syncState();
    if (!_enabled) {
      throw const ProviderConfigException('记忆召回未启用，无需重建。');
    }
    _scheduleBuild();
    _state = EpisodeRagState.preparing;
    _reason = null;
    return status();
  }

  /// 维护独占排空：等已入链的构建推进到安全点（批次边界或完成）。
  Future<void> settlePendingWork() => _buildTask;

  /// 维护独占入口在排空前调用：暂停位置位后，新请求的构建在开头让路。
  void pauseBackgroundScheduling() => _paused = true;

  /// 维护结束后恢复常规调度。
  void resumeBackgroundScheduling() => _paused = false;

  /// 维护（导入/回滚/清除）完成后的缓存失效（Spec 决策 7）：维护完成
  /// 后不得发布旧来源的在途结果，缓存一律失效并显示需重建；清空已
  /// 加载的缓存索引，在途构建凭代数错位自行放弃发布。
  void onMaintenanceCompleted() {
    _maintenanceGeneration += 1;
    if (_enabled) {
      _loadedIndex = null;
      _state = EpisodeRagState.rebuildNeeded;
      _reason = '记忆数据刚经历过维护（导入/回滚/清除），请重建索引。';
      _progressDone = 0;
      _progressTotal = 0;
    }
  }

  /// 语义查询定位（Spec 决策「隐藏动作与回答交付」）：查询向量与索引
  /// 逐条精确余弦，取最多 10 条候选，回读当前来源并核对有效性、控制
  /// 状态与来源 hash。查询失败按一次失败处理：不销毁仍有效的索引，
  /// 不冒充没有候选。
  ///
  /// 出网前查询先过秘密脱敏（Spec：查询 embedding 只接收脱敏后的
  /// query；秘密脱敏覆盖召回外发等一切出仓内容）——这是 embedding
  /// 外发的唯一边界，调用方传入的 query 在此统一脱敏。
  Future<EpisodeRagLocateResult> locate(String query) async {
    try {
      await _syncState();
      if (!_enabled) {
        return const RagNotEnabled();
      }
      if (_state != EpisodeRagState.ready || _loadedIndex == null) {
        return RagUnavailable('rag unavailable reason=${_state.wireName}');
      }
      final index = _loadedIndex!;
      // 空库（零条就绪）：没有可命中的记录，查询不外发。
      if (index.entries.isEmpty) {
        return const RagCandidates([]);
      }
      final cleanQuery = redactSessionText(query).trim();
      if (cleanQuery.isEmpty) {
        // 整句都是秘密：脱敏后无事可查，绝不外发原文。
        return const RagCandidates([]);
      }
      final config = await configRepository.loadEmbedding();
      if (config == null ||
          !_identityMatches(index.identity, config) ||
          !config.enabled) {
        // 查询瞬间身份或启用位已漂移：明确不可用，不猜。
        return const RagUnavailable('rag unavailable reason=identity-changed');
      }
      final vectors = await embeddingClient.embed(
        config: config,
        apiKey: config.apiKey,
        inputs: [cleanQuery],
      );
      final queryVector = vectors.single;
      if (queryVector.length != index.identity.dimension) {
        // 同名模型返回了不同维度：余弦不可计算，按查询失败处理。
        return const RagUnavailable(
          'rag unavailable reason=query-dimension-mismatch',
        );
      }
      final candidates = index.topByCosine(queryVector, episodeRagQueryLimit);
      return await _readback(candidates);
    } on EmbeddingGatewayException catch (error) {
      diagnosticsSink('episode rag query deferred kind=${error.kind.name}');
      return RagUnavailable('rag query deferred kind=${error.kind.name}');
    } on Object catch (error) {
      diagnosticsSink('episode rag query deferred [$error]');
      return RagUnavailable('rag query deferred [$error]');
    }
  }

  /// 候选回读（Spec 决策 5：查询发送、候选回读共用来源有效性规则）：
  /// 共享的来源核对见 [revalidateEpisodeSource]——存在、有效、控制与
  /// 来源 hash 逐条核过，再按会话脱敏规则过滤文本（与旧路径回读同一
  /// 套口径）。
  Future<RagCandidates> _readback(List<EpisodeRagIndexEntry> candidates) async {
    final banned = await _controlledTitles();
    final diagnostics = <String>[];
    final hits = <EpisodeRagHit>[];
    for (final candidate in candidates) {
      final entry = await revalidateEpisodeSource(
        pipeline: episodePipeline,
        date: candidate.date,
        entryId: candidate.entryId,
        expectedInputHash: candidate.inputSha256,
        banned: banned,
        diagnostics: diagnostics,
        diagnosticPrefix: 'rag candidate',
      );
      if (entry == null) {
        continue;
      }
      hits.add(
        EpisodeRagHit(
          date: candidate.date,
          entry: entry.redactedForModel(),
          inputSha256: candidate.inputSha256,
        ),
      );
    }
    return RagCandidates(hits, diagnostics: diagnostics);
  }

  // ---------- 状态同步 ----------

  /// 与持久化事实对齐：读启用位；启用时确保缓存已加载并核对身份。
  /// 幂等，每次状态读取与查询前调用。
  Future<void> _syncState({bool forceReload = false}) async {
    final config = await _readConfig();
    final enabled = config?.enabled ?? false;
    _enabled = enabled;
    if (!enabled) {
      if (_state != EpisodeRagState.preparing) {
        _state = EpisodeRagState.disabled;
        _reason = null;
        _progressDone = 0;
        _progressTotal = 0;
      }
      return;
    }
    switch (_state) {
      case EpisodeRagState.disabled:
        // 启用位为真但本地状态还没跟上（重启恢复 / 外部改配置）：
        // 加载缓存并按身份落到就绪或需重建。
        await _adoptCachedIndex(config, forceReload: forceReload);
      case EpisodeRagState.ready:
        // 就绪中身份漂移（换地址/模型/输入格式）：旧索引停止查询。
        final loaded = _loadedIndex;
        if (loaded == null ||
            (config != null && !_identityMatches(loaded.identity, config))) {
          _state = EpisodeRagState.rebuildNeeded;
          _loadedIndex = null;
          _reason = '记忆召回服务或模型已更换，请重建索引。';
        }
      case EpisodeRagState.preparing:
      case EpisodeRagState.unavailable:
      case EpisodeRagState.rebuildNeeded:
        // 构建链与失败/需重建状态由对应流程推进，这里不覆盖。
        break;
    }
  }

  /// 加载缓存索引并按当前配置身份落状态：可读且身份匹配 → 就绪；
  /// 缺失/损坏/身份不符 → 需重建。
  Future<void> _adoptCachedIndex(
    EmbeddingConfig? config, {
    bool forceReload = false,
  }) async {
    if (_loadedIndex == null || forceReload) {
      _loadedIndex = await _indexStore.read();
    }
    final loaded = _loadedIndex;
    if (loaded == null) {
      _state = EpisodeRagState.rebuildNeeded;
      _reason = '记忆召回索引缺失或损坏，请重建。';
      return;
    }
    if (config == null || !_identityMatches(loaded.identity, config)) {
      _loadedIndex = null;
      _state = EpisodeRagState.rebuildNeeded;
      _reason = '记忆召回服务或模型已更换，请重建索引。';
      return;
    }
    _state = EpisodeRagState.ready;
    _reason = null;
    _progressDone = 0;
    _progressTotal = 0;
  }

  /// 索引身份与当前配置是否匹配：规范化地址、模型与输入格式版本一致
  /// 即匹配（维度以缓存记录为准——它是构建时的实际值）。
  bool _identityMatches(EpisodeRagIndexIdentity identity, EmbeddingConfig config) =>
      identity.normalizedBaseUrl ==
          normalizeProviderBaseUri(config.baseUrl).toString() &&
      identity.model == config.model.trim() &&
      identity.inputFormatVersion == episodeRagInputFormatVersion;

  Future<EmbeddingConfig?> _readConfig() => configRepository.loadEmbedding();

  Future<Set<String>> _controlledTitles() =>
      openLoopStore?.controlledTitles() ?? Future.value(const <String>{});

  // ---------- 后台完整构建 ----------

  void _scheduleBuild() {
    Future<void> run() async {
      final generation = _maintenanceGeneration;
      try {
        await _runBuild(generation);
      } on EmbeddingGatewayException catch (error) {
        _state = EpisodeRagState.unavailable;
        _reason = error.message;
        _progressDone = 0;
        diagnosticsSink(
          'episode rag build deferred kind=${error.kind.name}',
        );
      } on Object catch (error) {
        _state = EpisodeRagState.unavailable;
        _reason = '记忆召回索引构建失败，请重试。';
        _progressDone = 0;
        diagnosticsSink('episode rag build deferred [$error]');
      }
    }

    final task = _buildTask.then((_) => run());
    _buildTask = task.then<void>((_) {}, onError: (_) {});
  }

  Future<void> _runBuild(int generation) async {
    if (_paused) {
      // 维护进行中不接受新构建：明确落为需重建，等用户稍后再点。
      _state = EpisodeRagState.rebuildNeeded;
      _reason = '本机维护进行中，请稍后重建。';
      return;
    }
    final config = await _readConfig();
    if (config == null || !config.enabled) {
      // 启用位已撤（构建入链后被停用）：静默放弃，不发布。
      return;
    }
    _state = EpisodeRagState.preparing;
    _reason = null;
    _progressDone = 0;
    _progressTotal = 0;

    // 枚举当前有效 episodes（Spec 决策 1）：排除空、簿记与关系信号
    // 条目；受控（禁提/删除/冻结）条目不入索引；sessions、月摘要、
    // PersonaTree 与归档画像从不进入枚举范围。
    final banned = await _controlledTitles();
    final jobs = <_BuildJob>[];
    for (final date in await episodePipeline.listEpisodeDates()) {
      final day = await episodePipeline.readDay(date);
      if (!day.readable) {
        continue;
      }
      for (final entry in validEpisodeEntries(day.entries)) {
        if (bannedMemoryText(entry.summary, banned)) {
          continue;
        }
        final input = episodeRagEmbeddingInput(date, entry.summary);
        jobs.add((
          date: date,
          entryId: entry.id,
          input: input,
          inputSha256: episodeRagInputHash(input),
        ));
      }
    }
    _progressTotal = jobs.length;

    final vectors = <EpisodeRagIndexEntry>[];
    var dimension = 0;
    for (var start = 0; start < jobs.length; start += episodeRagBatchSize) {
      if (_maintenanceGeneration != generation || !_enabled) {
        // 维护开始或构建中被停用：放弃，不发布任何部分索引。
        return;
      }
      final end = (start + episodeRagBatchSize).clamp(0, jobs.length);
      final batch = jobs.sublist(start, end);
      final results = await embeddingClient.embed(
        config: config,
        apiKey: config.apiKey,
        inputs: [for (final job in batch) job.input],
        timeout: episodeRagBatchTimeout,
      );
      for (var i = 0; i < batch.length; i++) {
        final vector = results[i];
        if (dimension == 0) {
          dimension = vector.length;
        } else if (vector.length != dimension) {
          // 批间维度不一致：不合法响应不可进入有效索引。
          throw EmbeddingGatewayException(
            kind: ModelFailureKind.incompatibleResponse,
            message: '记忆召回服务返回的向量维度不一致，无法建索引。',
          );
        }
        vectors.add(
          EpisodeRagIndexEntry(
            date: batch[i].date,
            entryId: batch[i].entryId,
            inputSha256: batch[i].inputSha256,
            vector: vector,
          ),
        );
      }
      _progressDone = end;
    }

    // 发布前重核来源与控制状态（Spec 决策 2）：构建期间被编辑、删除、
    // 禁提或冻结的条目不进入发布的索引。
    if (_maintenanceGeneration != generation || !_enabled) {
      return;
    }
    final recheckBanned = await _controlledTitles();
    final published = <EpisodeRagIndexEntry>[];
    final recheckDiagnostics = <String>[];
    for (final vector in vectors) {
      final entry = await revalidateEpisodeSource(
        pipeline: episodePipeline,
        date: vector.date,
        entryId: vector.entryId,
        expectedInputHash: vector.inputSha256,
        banned: recheckBanned,
        diagnostics: recheckDiagnostics,
        diagnosticPrefix: 'rag publish recheck',
      );
      if (entry == null) {
        continue;
      }
      published.add(vector);
    }
    if (_maintenanceGeneration != generation || !_enabled) {
      // 重核期间维护开始或被停用：放弃，不发布。
      return;
    }
    final index = EpisodeRagIndex(
      identity: EpisodeRagIndexIdentity.identityFor(config, dimension),
      entries: published,
    );
    await _indexStore.publish(index);
    _loadedIndex = index;
    _state = EpisodeRagState.ready;
    _reason = null;
  }
}

/// 一条待向量化的构建任务：embedding 输入与其 hash 同源生成。
typedef _BuildJob = ({
  String date,
  String entryId,
  String input,
  String inputSha256,
});

/// 候选回读、发布前重核与下一轮消费共用的来源有效性核对（Spec 决策 5：
/// 后台同步、查询发送、候选回读与下一轮消费共用来源有效性规则）：按
/// 当前日文件核对条目仍存在、仍有效、未命中控制范围；RAG 候选
/// （[expectedInputHash] 非空）另核输入 hash 未变——摘要或日期已变即
/// 旧向量立即不可用。摘录命中受控范围时丢摘录保摘要。通过时返回当前
/// 条目（未脱敏，调用方按出口自行脱敏）；不通过返回 null 并把原因写入
/// [diagnostics]（[diagnosticPrefix] 区分调用方，只进本机诊断）。
Future<EpisodeEntry?> revalidateEpisodeSource({
  required EpisodeMemoryPipeline pipeline,
  required String date,
  required String entryId,
  required String? expectedInputHash,
  required Set<String> banned,
  required List<String> diagnostics,
  required String diagnosticPrefix,
}) async {
  final day = await pipeline.readDay(date);
  if (!day.readable) {
    diagnostics.add('$diagnosticPrefix dropped date=$date reason=unreadable');
    return null;
  }
  final current = day.entries
      .where((match) => match.id == entryId)
      .firstOrNull;
  if (current == null) {
    diagnostics.add('$diagnosticPrefix dropped id=$entryId reason=source-gone');
    return null;
  }
  if (validEpisodeEntries([current]).isEmpty) {
    diagnostics.add(
      '$diagnosticPrefix dropped id=$entryId reason=invalid-entry',
    );
    return null;
  }
  if (bannedMemoryText(current.summary, banned)) {
    diagnostics.add('$diagnosticPrefix dropped id=$entryId reason=blocked');
    return null;
  }
  var kept = current;
  if (current.evidence != null &&
      bannedMemoryText(current.evidence!, banned)) {
    // 摘要未命中但原话摘录命中受控范围：丢摘录保摘要。
    diagnostics.add(
      '$diagnosticPrefix evidence dropped id=$entryId reason=blocked',
    );
    kept = EpisodeEntry(
      id: current.id,
      sessionId: current.sessionId,
      requestId: current.requestId,
      summary: current.summary,
      at: current.at,
      kind: current.kind,
      signal: current.signal,
    );
  }
  final hash = expectedInputHash;
  if (hash != null) {
    final currentHash = episodeRagInputHash(
      episodeRagEmbeddingInput(date, kept.summary),
    );
    if (currentHash != hash) {
      diagnostics.add(
        '$diagnosticPrefix dropped id=$entryId reason=stale-source',
      );
      return null;
    }
  }
  return kept;
}
