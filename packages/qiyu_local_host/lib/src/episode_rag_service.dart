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

/// 召回状态的六个展示口径（Spec 表「设置与聊天状态」）：未启用、准备中
/// （首次完整构建）、已就绪、更新中（增量同步处理新条目与变更条目）、
/// 需重建、暂不可用。
enum EpisodeRagState {
  disabled('disabled'),
  preparing('preparing'),
  ready('ready'),
  updating('updating'),
  rebuildNeeded('rebuildNeeded'),
  unavailable('unavailable');

  const EpisodeRagState(this.wireName);

  final String wireName;
}

/// 召回状态快照：经 HTTP 返回时只含状态名、进度、待处理量与人话原因，
/// 不含地址以外的服务细节，绝不携带 Key。
final class EpisodeRagStatus {
  const EpisodeRagStatus({
    required this.state,
    this.progressDone = 0,
    this.progressTotal = 0,
    this.pendingCount = 0,
    this.reason,
  });

  final EpisodeRagState state;

  /// 准备中或更新中的完成量（本趟已完成条目数 / 本趟总条目数）；其余
  /// 状态为 0。
  final int progressDone;
  final int progressTotal;

  /// 增量同步尚待嵌入的条目数（新条目、摘要/日期变化条目与上次更新
  /// 失败保留的条目）。更新中与「就绪但有未完成更新」时大于 0。
  final int pendingCount;

  /// 暂不可用或需重建的简短人话原因；就绪状态下仅在增量更新未完成
  /// 待重试时携带原因；其余状态为 null。
  final String? reason;

  Map<String, Object?> toJson() => {
    'state': state.wireName,
    'progressDone': progressDone,
    'progressTotal': progressTotal,
    'pendingCount': pendingCount,
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

  /// 增量同步尚待嵌入的条目数：同步任务扫描后记账，逐批递减；更新
  /// 失败时保留（重试或下一次来源变化触发时再消化）。
  int _pendingCount = 0;

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
      pendingCount: _pendingCount,
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
  /// 旧目录；在途构建与增量同步在批次边界发现停用后放弃，不发布。
  /// 缓存文件保留，重新启用时同身份可直接就绪。
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
    _pendingCount = 0;
    return status();
  }

  /// 明确重建/重试（Spec：需重建与暂不可用都提供明确重试入口）：无有
  /// 效索引时按当前配置完整重建；已有有效索引时（增量更新失败待重试）
  /// 走便宜的增量对账，只重嵌待处理条目，不整库重算。未启用时重建是
  /// 无效操作。
  Future<EpisodeRagStatus> rebuild() async {
    await _syncState();
    if (!_enabled) {
      throw const ProviderConfigException('记忆召回未启用，无需重建。');
    }
    if (_state == EpisodeRagState.ready && _loadedIndex != null) {
      scheduleIncrementalSync();
      return status();
    }
    _scheduleBuild();
    _state = EpisodeRagState.preparing;
    _reason = null;
    return status();
  }

  /// 来源或控制变化后的增量同步调度（票 04）：episode 保存、记忆中心
  /// 编辑/删除/冻结/禁提与启动来源扫描都汇到这一个入口——网络在任务
  /// 链上（记忆锁之外）执行，不阻塞保存或可见回复；同一时刻至多一个
  /// 同步在推进，与完整构建同链串行。未启用、维护暂停或无有效索引时
  /// 调度是空操作（完整构建与维护失效各自负责那些状态）。
  void scheduleIncrementalSync() {
    Future<void> run() async {
      final generation = _maintenanceGeneration;
      try {
        await _runIncrementalSync(generation);
      } on Object catch (error) {
        // 同步是后台增强：任何未预期失败都保留仍有效索引与待处理
        // 记账，等待显式重试或下一次来源变化，不无限立即重试。
        diagnosticsSink('episode rag update deferred [$error]');
        if (_state == EpisodeRagState.updating &&
            _maintenanceGeneration == generation &&
            _enabled) {
          _state = EpisodeRagState.ready;
          _progressDone = 0;
          _progressTotal = 0;
          _reason ??= '记忆召回索引更新失败，请重试。';
        }
      }
    }

    final task = _buildTask.then((_) => run());
    _buildTask = task.then<void>((_) {}, onError: (_) {});
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
    _pendingCount = 0;
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
      // 更新中（增量同步在途）仍可查询：仍有效的已有条目照常命中，
      // 新条目允许短暂缺口（Spec：增量期间只检索仍有效的旧条目）。
      if ((_state != EpisodeRagState.ready &&
              _state != EpisodeRagState.updating) ||
          _loadedIndex == null) {
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
          _pendingCount = 0;
        }
      case EpisodeRagState.preparing:
      case EpisodeRagState.updating:
      case EpisodeRagState.unavailable:
      case EpisodeRagState.rebuildNeeded:
        // 构建链与失败/需重建状态由对应流程推进，这里不覆盖。
        break;
    }
  }

  /// 加载缓存索引并按当前配置身份落状态：可读且身份匹配 → 就绪（并
  /// 调度一次来源扫描：宿主停用期间或 Host 未运行时的外部编辑、删除
  /// 与控制解除，由对账发现，不只沿用盘上旧索引）；缺失/损坏/身份不
  /// 符 → 需重建。
  Future<void> _adoptCachedIndex(
    EmbeddingConfig? config, {
    bool forceReload = false,
  }) async {
    final freshLoad = _loadedIndex == null || forceReload;
    if (freshLoad) {
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
    _pendingCount = 0;
    if (freshLoad) {
      // 启动/重启后的来源对账（票 04）：盘上索引只是缓存，当前来源
      // 才是事实——同步在任务链上后台执行，不阻塞状态读取。
      scheduleIncrementalSync();
    }
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
    // 全量重建接管一切增量欠账：待处理记账清零，防陈旧标志残留。
    _pendingCount = 0;

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

  // ---------- 增量同步（票 04） ----------

  /// 增量同步主体：重新扫描当前有效 episodes，与已加载索引对账——仍
  /// 有效且输入未变的记录保留；新条目与摘要/日期变化（旧输入 hash 失
  /// 配）的条目重新嵌入；删除、禁提、冻结、失效或来源消失的条目从发
  /// 布结果中剔除。网络嵌入在记忆锁之外的本任务链上执行；发布前重核
  /// 来源与控制状态（Spec 决策 2/5），在途请求期间的变化不得把旧结果
  /// 重新写回为有效向量。
  ///
  /// 状态推进：有待嵌入任务时先落「更新中」（待处理量随批次递减），
  /// 收尾回「就绪」；部分失败时保留待处理记账与人话原因，仍有效索引
  /// 照常可查，等待显式重试（[rebuild] 的就绪分支）或下一次来源变化
  /// 触发，不立即无限重试。
  Future<void> _runIncrementalSync(int generation) async {
    if (_paused) {
      // 维护独占进行中：让路，不扫描也不发布；维护完成后的缓存失效与
      // 重建或下一次触发接管。
      return;
    }
    final config = await _readConfig();
    if (config == null || !config.enabled) {
      return;
    }
    final index = _loadedIndex;
    if (index == null) {
      // 无有效索引（未就绪/需重建/维护失效）：增量无从谈起，完整
      // 构建负责。
      return;
    }
    if (!_identityMatches(index.identity, config)) {
      // 身份已漂移：需重建状态由 _syncState 落定，这里不嵌不入。
      return;
    }
    if (_state != EpisodeRagState.ready &&
        _state != EpisodeRagState.updating) {
      // 准备中（完整构建在途，发布前自带重核）、需重建、暂不可用：
      // 增量不越过对应流程。
      return;
    }

    // 1. 扫描当前有效来源（Spec 决策 5：与查询、回读、下一轮消费同一
    // 套有效性规则）：排除空、簿记与关系信号条目；受控（禁提/删除/
    // 冻结）条目不入索引；sessions、月摘要、PersonaTree 与归档画像从
    // 不进入枚举范围。手工外部编辑即使没有写入回调，也由本次扫描发现。
    final banned = await _controlledTitles();
    final current = <String, _BuildJob>{};
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
        current['$date|${entry.id}'] = (
          date: date,
          entryId: entry.id,
          input: input,
          inputSha256: episodeRagInputHash(input),
        );
      }
    }

    // 2. 对账：输入未变的记录保留；新条目与 hash 失配条目（摘要或日期
    // 已变）入待嵌入队列；索引里指向已消失、受控或失效来源的记录剔除。
    final byKey = <String, EpisodeRagIndexEntry>{
      for (final record in index.entries)
        '${record.date}|${record.entryId}': record,
    };
    final kept = <EpisodeRagIndexEntry>[];
    final jobs = <_BuildJob>[];
    current.forEach((key, job) {
      final existing = byKey[key];
      if (existing != null && existing.inputSha256 == job.inputSha256) {
        kept.add(existing);
      } else {
        jobs.add(job);
      }
    });
    if (jobs.isEmpty && kept.length == index.entries.length) {
      // 索引与当前来源一致：无事可做，不发布、不改状态。
      return;
    }

    // 3. 嵌入待处理条目（每批最多 10 条、每批 30 秒）。网络在锁外：
    // 本任务链不持有任何记忆锁，嵌入窗口内来源可以继续变化。
    if (jobs.isNotEmpty) {
      _state = EpisodeRagState.updating;
      _reason = null;
      _progressDone = 0;
      _progressTotal = jobs.length;
      _pendingCount = jobs.length;
    }
    // 零条就绪索引（空库）维度记 0：以首批实际向量补齐身份维度。
    var dimension = index.entries.isEmpty ? 0 : index.identity.dimension;
    final embedded = <EpisodeRagIndexEntry>[];
    String? failure;
    for (var start = 0; start < jobs.length; start += episodeRagBatchSize) {
      if (_maintenanceGeneration != generation || !_enabled) {
        // 维护开始或构建链入队后被停用：放弃本趟，不发布（维护完成会
        // 整体失效缓存；停用后索引文件保留待重新启用对账）。
        return;
      }
      final end = (start + episodeRagBatchSize).clamp(0, jobs.length);
      final batch = jobs.sublist(start, end);
      try {
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
            // 增量向量必须与现有索引同维：余弦不可计算，按本趟失败
            // 处理，不合法响应不进入有效索引。
            throw EmbeddingGatewayException(
              kind: ModelFailureKind.incompatibleResponse,
              message: '记忆召回服务返回的向量维度与现有索引不一致，无法更新索引。',
            );
          }
          embedded.add(
            EpisodeRagIndexEntry(
              date: batch[i].date,
              entryId: batch[i].entryId,
              inputSha256: batch[i].inputSha256,
              vector: vector,
            ),
          );
        }
        _progressDone = end;
        _pendingCount = jobs.length - end;
      } on EmbeddingGatewayException catch (error) {
        // 失败即停：本趟已成功的条目随发布保留，其余留待处理，不
        // 立即无限重试。
        failure = error.message;
        diagnosticsSink('episode rag update deferred kind=${error.kind.name}');
        break;
      } on Object catch (error) {
        failure = '记忆召回索引更新失败，请重试。';
        diagnosticsSink('episode rag update deferred [$error]');
        break;
      }
    }

    // 4. 发布前重核来源与控制状态（Spec 决策 2）：嵌入窗口内被编辑、
    // 删除、禁提或冻结的条目不得随本趟结果重新写回为有效向量。
    if (_maintenanceGeneration != generation) {
      return;
    }
    if (!_enabled) {
      _state = EpisodeRagState.disabled;
      _reason = null;
      _progressDone = 0;
      _progressTotal = 0;
      _pendingCount = 0;
      return;
    }
    final recheckBanned = await _controlledTitles();
    final published = <EpisodeRagIndexEntry>[];
    final recheckDiagnostics = <String>[];
    for (final record in [...kept, ...embedded]) {
      final entry = await revalidateEpisodeSource(
        pipeline: episodePipeline,
        date: record.date,
        entryId: record.entryId,
        expectedInputHash: record.inputSha256,
        banned: recheckBanned,
        diagnostics: recheckDiagnostics,
        diagnosticPrefix: 'rag update recheck',
      );
      if (entry == null) {
        continue;
      }
      published.add(record);
    }
    if (_maintenanceGeneration != generation || !_enabled) {
      return;
    }
    // 5. 原子发布：与完整构建同一发布路径——读者要么看到旧索引，要么
    // 看到完整新索引。发布失败时旧索引保持加载，仍可查询。
    final updated = EpisodeRagIndex(
      identity: index.entries.isEmpty
          ? EpisodeRagIndexIdentity.identityFor(config, dimension)
          : index.identity,
      entries: published,
    );
    try {
      await _indexStore.publish(updated);
    } on Object catch (error) {
      diagnosticsSink('episode rag update deferred [$error]');
      _state = EpisodeRagState.ready;
      _progressDone = 0;
      _progressTotal = 0;
      _pendingCount = jobs.length;
      _reason = '记忆召回索引保存失败，请重试。';
      return;
    }
    _loadedIndex = updated;
    final pending = jobs.length - embedded.length;
    _state = EpisodeRagState.ready;
    _progressDone = 0;
    _progressTotal = 0;
    _pendingCount = pending;
    _reason = pending > 0 ? (failure ?? '记忆召回索引更新未完成，请重试。') : null;
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
