import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';
import 'package:path/path.dart' as path;

import 'anysearch_client.dart';
import 'api_http.dart';
import 'backup_routes.dart';
import 'browser_launcher.dart';
import 'chat_memory_module.dart';
import 'chat_routes.dart';
import 'daily_finalization.dart';
import 'developer_diagnostics.dart';
import 'delivery_stream_state.dart';
import 'dream.dart';
import 'embedding_gateway.dart';
import 'embedding_settings_service.dart';
import 'episode_memory.dart';
import 'episode_rag_service.dart';
import 'hidden_action_executor.dart';
import 'local_chat_service.dart';
import 'local_data_service.dart';
import 'markdown_memory_repository.dart';
import 'memory_actions.dart';
import 'memory_backup.dart';
import 'memory_cadence.dart';
import 'memory_center.dart';
import 'memory_controls.dart';
import 'memory_recall.dart';
import 'memory_recovery.dart';
import 'memory_routes.dart';
import 'model_gateway.dart';
import 'model_prompt_builder.dart';
import 'monthly_summary.dart';
import 'omni_call_routes.dart';
import 'omni_call_service.dart';
import 'onboarding_routes.dart';
import 'onboarding_state.dart';
import 'open_loop_store.dart';
import 'persona_tree.dart';
import 'provider_config.dart';
import 'provider_settings_service.dart';
import 'provider_web_socket.dart';
import 'qwen_omni_realtime_gateway.dart';
import 'proxy_settings_service.dart';
import 'relationship_lifecycle.dart';
import 'secure_token.dart';
import 'secret_store.dart';
import 'settings_routes.dart';
import 'state_pack_reader.dart';
import 'stt_gateway.dart';
import 'stt_settings_service.dart';
import 'tts_gateway.dart';
import 'tts_settings_service.dart';
import 'voice_routes.dart';
import 'web_search_settings_service.dart';

const _sessionCookieName = 'qiyu_session';
const _csrfHeaderName = 'x-qiyu-csrf';

final class LocalAppHost {
  LocalAppHost._(
    this._server,
    this._requestHandler,
    this._idleCatchupPoller,
    this._memoryCadence,
    this._chatService,
  );

  final HttpServer _server;
  final _LocalAppRequestHandler _requestHandler;
  final IdleCatchupPoller _idleCatchupPoller;
  final MemoryCadence _memoryCadence;

  /// 关闭收尾依赖：组合根启动时创建、并已交给聊天与备份路由的
  /// 同一个 [LocalChatService] 实例（不是第二个实例），在途召回收尾
  /// 必须由 Host 自己等它，不借道安全请求入口取回。
  final LocalChatService _chatService;

  InternetAddress get address => _server.address;

  int get port => _server.port;

  Uri get origin => Uri(scheme: 'http', host: address.address, port: port);

  Uri get launchUri => origin.replace(
    path: '/_session/start',
    queryParameters: {'token': _requestHandler.startupToken},
  );

  /// 记忆节奏（ticket 22）：空闲补办轮询 tick 的宿主侧通道（spec：
  /// 唯一新缝是记忆节奏的轮询 tick；测试由此拨动 tick 而不启动真定时器）。
  MemoryCadence get memoryCadence => _memoryCadence;

  static Future<LocalAppHost> start({
    required String webRoot,
    required String memoryDirectory,
    required String personaConstitution,
    String? personaConstitutionEn,
    String? activationToken,
    Future<BrowserLaunchResult> Function()? onActivate,
    ProviderSettingsService? providerSettingsService,
    // 凭据仓注入（凭据仓接口定义在本包，平台壳注入实现）：生产壳
    // （Windows/Android）装配时必须传入平台凭据仓；缺省只是内存易失
    // 仓，供组合根测试与未配置场景，Key 不落盘。
    SecretStore? secretStore,
    WebSearchSettingsService? webSearchSettingsService,
    SttSettingsService? sttSettingsService,
    TtsSettingsService? ttsSettingsService,
    EmbeddingSettingsService? embeddingSettingsService,
    EpisodeRagService? episodeRagService,
    // 时钟、原子写入、交付停顿与诊断出口沿用各组件既有的注入接缝，
    // 缺省全部走生产默认；测试由此在真路径上获得确定性。
    Clock? clock,
    AtomicTextWriter? atomicWriter,
    DeliveryPause? deliveryPause,
    RecallWindowWait? recallWindowWait,
    // 连续供给会话落定的有界宽限（票三）：缺省走生产值，测试注入小值。
    Duration? voiceSessionGrace,
    void Function(String message)? diagnosticsSink,
    IdleCatchupPoller? idleCatchupPoller,
  }) async {
    final indexFile = File('$webRoot${Platform.pathSeparator}index.html');
    if (!indexFile.existsSync()) {
      throw ArgumentError.value(webRoot, 'webRoot', 'index.html not found');
    }

    if ((activationToken == null) != (onActivate == null)) {
      throw ArgumentError(
        'activationToken and onActivate must either both be set or both be null',
      );
    }
    final modelPromptBuilder = ModelPromptBuilder(
      personaConstitution,
      personaConstitutionEn: personaConstitutionEn,
    );
    final runtimeDirectory = Directory(memoryDirectory).parent.path;
    final providerConfigRepository = JsonProviderConfigRepository(
      filePath: path.join(runtimeDirectory, 'provider.json'),
    );
    // 出站代理（ticket 08）：设置面与模型网关出网共用同一份 provider.json
    // `proxy` 段；每次请求现读现判，保存后下一条请求即生效。
    final proxySettingsService = ProxySettingsService(providerConfigRepository);
    // 聊天出网分两路：直连客户端照旧服务 Ollama、联网搜索与本地语音
    // 之外的一切；代理客户端只服务 OpenAI 兼容／Anthropic 的模型调用
    //（分叉在 ProviderModelGateway._outboundFor，局域网目标在客户端
    // 内再摘一层）。语音直连网关（豆包 volc）各自装配独立直连客户端，
    // 结构上不经过代理。
    const directProviderHttpClient = DartIoProviderHttpClient();
    final proxiedProviderHttpClient = DartIoProviderHttpClient(
      proxyRulesSource: proxySettingsService.loadRules,
    );
    final effectiveProviderSettings =
        providerSettingsService ??
        ProviderSettingsService(
          providerConfigRepository,
          secretStore ?? _VolatileSecretStore(),
          ProviderModelGateway(
            directProviderHttpClient,
            proxyHttpClient: proxiedProviderHttpClient,
            diagnosticsSink: diagnosticsSink,
          ),
          modelPromptBuilder,
          webSearchConfigRepository: providerConfigRepository,
          // 联网搜索（AnySearch）是独立的国内服务，保持直连不走代理。
          webSearchClient: const AnySearchClient(directProviderHttpClient),
          // Omni 实时会话网关（T02）：qwen_omni_realtime 档的实时连接与
          // 文字接线共用同一 WS 连接子，与语音 WS 网关同律直连不走代理。
          omniRealtimeGateway: QwenOmniRealtimeGateway(
            const DartIoProviderWebSocketConnector(),
            diagnosticsSink: diagnosticsSink,
          ),
        );
    final effectiveWebSearchSettings =
        webSearchSettingsService ??
        WebSearchSettingsService(providerConfigRepository);
    // 语音转写（STT）：与聊天 Provider 共用 provider.json（stt 段）与
    // 出网 HTTP 抽象，但配置与 Key 作用域独立（ADR 0001）。
    final effectiveSttSettings =
        sttSettingsService ??
        SttSettingsService(
          providerConfigRepository,
          SttModelGateway(DartIoProviderHttpClient()),
        );
    // 语音朗读（TTS）：同一套律（ADR 0002：整段合成、tts 段独立）。
    // 票三起连续喂文本走 WS：豆包双向 / 千问 Realtime 两个协议网关经
    // 同一 WS 连接子出网（与 STT 豆包流式识别同接缝），WS 地址由 Host
    // 从 baseUrl 派生并同样过出网校验（ADR 0019）。
    final effectiveTtsSettings =
        ttsSettingsService ??
        TtsSettingsService(
          providerConfigRepository,
          TtsModelGateway(
            DartIoProviderHttpClient(),
            webSocketConnector: const DartIoProviderWebSocketConnector(),
          ),
        );
    // 记忆召回（Episode RAG）embedding 设置：独立 embedding 段与出网
    // 客户端（ADR 0027）。保存／测试／忘记 Key 不启用 RAG；显式启用后
    // 由 [EpisodeRagService] 完成索引构建与语义定位（票 03）。服务实例
    // 由组合根创建一个，文字轮内召回与实时查找共享；测试可整体注入。
    final effectiveEmbeddingSettings =
        embeddingSettingsService ??
        EmbeddingSettingsService(
          providerConfigRepository,
          OpenAiEmbeddingGateway(DartIoProviderHttpClient()),
        );
    // 开发者诊断（ticket 23）：最近请求环形缓冲 + 体验选项持久化。
    // 记录器结构上不收用户文本，诊断端点只读、默认不启用。
    final requestDiagnostics = RequestDiagnosticsRecorder();
    final experienceRepository = JsonExperienceSettingsRepository(
      filePath: path.join(runtimeDirectory, 'experience.json'),
    );
    final memoryRepository = MarkdownMemoryRepository(
      memoryDirectory: memoryDirectory,
      clock: clock,
      atomicWriter: atomicWriter,
    );
    final episodePipeline = EpisodeMemoryPipeline(
      memoryDirectory: memoryDirectory,
      clock: clock,
      atomicWriter: atomicWriter,
    );
    // 用户记忆控制记录的唯一读写者（ticket 18）：Open-loop 热层与
    // 聊天即时生效两条路径共享同一实例，避免双写覆盖。
    final memoryControls = MemoryControlsStore(
      memoryDirectory: memoryDirectory,
      atomicWriter: atomicWriter,
      commits: episodePipeline.commits,
    );
    // Open-loop 生命周期由日终归档与对话即时生效两条路径共享同一存储。
    final openLoopStore = OpenLoopStore(
      memoryDirectory: memoryDirectory,
      memoryControls: memoryControls,
      atomicWriter: atomicWriter,
    );
    // 关系生命周期由日终归档与删除即时清除共享同一实例。
    final relationshipLifecycle = RelationshipLifecycle(
      memoryDirectory: memoryDirectory,
      atomicWriter: episodePipeline.commits.wrap(atomicWriter),
      clock: clock,
    );
    // PersonaTree 同样由随手记建叶与日终整理两条路径共享同一实例：
    // 树文件串行锁在实例内部，必须唯一。
    final personaTree = PersonaTreeStore(
      memoryDirectory: memoryDirectory,
      episodePipeline: episodePipeline,
      openLoopStore: openLoopStore,
      atomicWriter: atomicWriter,
    );
    // Episode RAG 服务（票 03）：显式启用后承担向量索引构建与语义定位。
    // 组合根创建一个实例，文字轮内召回、实时查找与设置操作共享。
    final effectiveEpisodeRag =
        episodeRagService ??
        EpisodeRagService(
          memoryDirectory: memoryDirectory,
          configRepository: providerConfigRepository,
          // embedding 出网与语音家族同律直连（不经聊天代理分叉）。
          embeddingClient: const OpenAiEmbeddingGateway(
            DartIoProviderHttpClient(),
          ),
          episodePipeline: episodePipeline,
          openLoopStore: openLoopStore,
          diagnosticsSink: diagnosticsSink ?? stderrDiagnostics,
          atomicWriter: atomicWriter,
        );
    // 月压缩由后台任务链触发（五段节奏第四动作），共享同一实例。
    final monthlySummary = MonthlySummaryStore(
      memoryDirectory: memoryDirectory,
      episodePipeline: episodePipeline,
      openLoopStore: openLoopStore,
      atomicWriter: atomicWriter,
    );
    // Dream（五段节奏第五动作）：晚安后与启动补跑时深度重组产出
    // 长期印象，并保守维护 PersonaTree 根节点与 persona.md 投影；
    // 与聊天共用同一 Provider 配置与凭据，未配置时不运行，绝不用规则
    // 补写长期内容。共享同一 PersonaTreeStore 实例（树文件串行锁唯一）。
    final dreamService = DreamService(
      memoryDirectory: memoryDirectory,
      episodePipeline: episodePipeline,
      openLoopStore: openLoopStore,
      monthlySummary: monthlySummary,
      personaTree: personaTree,
      modelClient: effectiveProviderSettings,
      clock: clock,
      atomicWriter: atomicWriter,
    );
    // 记忆动作执行端（ticket 20）：记忆中心 UI 的编辑、控制、删除
    // 与敏感揭示；聊天共用它的禁提执行器和删除管线，以及上述协调器。
    // 控制时关联扩展（裁定票 03）与聊天、日终、Dream 共用同一
    // Provider 配置与凭据：未配置时别名调用自动静默跳过。
    final memoryActions = MemoryActionService(
      memoryDirectory: memoryDirectory,
      episodePipeline: episodePipeline,
      personaTree: personaTree,
      memoryControls: memoryControls,
      openLoopStore: openLoopStore,
      monthlySummary: monthlySummary,
      relationshipLifecycle: relationshipLifecycle,
      atomicWriter: atomicWriter,
      aliasClient: effectiveProviderSettings,
    );
    // 损坏隔离与证据驱动恢复（ticket 21）：启动后台任务链上先于补
    // 归档执行；共享全部既有存储实例，写锁与各管线同律。
    final memoryRecovery = MemoryRecoveryService(
      memoryDirectory: memoryDirectory,
      episodePipeline: episodePipeline,
      memoryControls: memoryControls,
      personaTree: personaTree,
      dreamService: dreamService,
      monthlySummary: monthlySummary,
      relationshipLifecycle: relationshipLifecycle,
      memoryActions: memoryActions,
      clock: clock,
      atomicWriter: atomicWriter,
    );
    // Markdown 备份导出与导入（ticket 22）：只依赖记忆目录与各存储
    // 实例，验证、差异、快照、回滚全部在写入前完成；共享控制与动作
    // 实例，导入后按现行控制再清除派生内容。
    final memoryBackup = MemoryBackupService(
      memoryDirectory: memoryDirectory,
      memoryControls: memoryControls,
      episodePipeline: episodePipeline,
      personaTree: personaTree,
      memoryActions: memoryActions,
      clock: clock,
    );
    // 记忆节奏与聊天服务在构造期互需一个只读信号：节奏轮询要问聊天
    // 服务「有无在途交付」，聊天服务要持「交付完成钩子」。先声明后
    // 赋值的局部变量解开构造环；轮询定时器在两者装配完成后才启动，
    // 环窗期内让路信号恒为不忙（与迁移前在途队列为空的语义一致）。
    LocalChatService? wiredChatService;
    final memoryCadence = MemoryCadence(
      providerPort: effectiveProviderSettings,
      requestDiagnostics: requestDiagnostics,
      dailyFinalization: DailyFinalizationService(
        memoryDirectory: memoryDirectory,
        episodePipeline: episodePipeline,
        openLoopStore: openLoopStore,
        personaTree: personaTree,
        relationshipLifecycle: relationshipLifecycle,
        // 日终一次模型理解调用与聊天共用同一 Provider 配置与凭据；
        // 未配置时日终自动走全确定性路径。
        modelClient: effectiveProviderSettings,
        clock: clock,
        atomicWriter: atomicWriter,
      ),
      monthlySummary: monthlySummary,
      dreamService: dreamService,
      memoryRecovery: memoryRecovery,
      isDeliveryBusy: () => wiredChatService?.hasActiveDeliveries ?? false,
      clock: clock,
      diagnosticsSink: diagnosticsSink,
    );
    // 记忆依赖族（票 10 / ADR 0022）：与日终归档、记忆中心、备份等
    // 服务共享上面装配的同一批存储实例，控制存储与开环存储的同实例
    // 约束由 module 构造期校验兜底；Omni 实时通话（T03）共用同一实例。
    final chatMemoryModule = ChatMemoryModule(
      episodePipeline: episodePipeline,
      openLoopStore: openLoopStore,
      memoryControls: memoryControls,
      memoryActions: memoryActions,
      memoryCadence: memoryCadence,
      memoryRecall: RecallOrchestrator(
        memoryDirectory: memoryDirectory,
        episodePipeline: episodePipeline,
        // 轮内查找的选择/组织小调用与聊天共用同一 Provider 配置与
        // 凭据；未配置时轮内循环静默跳过（不召回保持现状）。
        modelClient: effectiveProviderSettings,
        openLoopStore: openLoopStore,
        // 画像树路径检索（Memory 注入定稿）：与选日同一调用顺带选路；
        // 树不可用或读取失败时路径检索静默跳过，episode 链路照常。
        personaTree: personaTree,
        // Episode RAG（票 03）：用户显式启用后就绪查询时语义定位替换
        // 目录选择；未启用时调用方走旧定位。组合根唯一实例。
        episodeRag: effectiveEpisodeRag,
      ),
      personaTree: personaTree,
      statePackReader: StatePackReader(
        memoryDirectory: memoryDirectory,
        openLoopStore: openLoopStore,
        clock: clock,
      ),
      embeddingRecall: effectiveEpisodeRag,
    );
    final chatService = LocalChatService(
      memoryRepository,
      memory: chatMemoryModule,
      providerPort: effectiveProviderSettings,
      requestDiagnostics: requestDiagnostics,
      modelPromptBuilder: modelPromptBuilder,
      deliveryPause: deliveryPause,
      recallWindowWait: recallWindowWait,
      voiceSessionGrace: voiceSessionGrace,
      clock: clock,
      diagnosticsSink: diagnosticsSink,
      // 分句流式语音合成（票二）：与朗读路由、连接测试共用同一个
      // TtsSettingsService 实例——配置、Key 与文本校验同一真相源。
      voiceStreamSynthesizer: effectiveTtsSettings,
      // 聊天冻结分支的关联扩展（禁提走 memoryActions 的禁提执行器，
      // 删除走它的删除管线，两处已随 memoryActions 注入同一客户端）。
      aliasClient: effectiveProviderSettings,
    );
    wiredChatService = chatService;
    await chatService.initialize();
    // Omni 双工实时通话（T03）：与聊天共享同一批记忆存储与执行器，
    // 经同一 Provider 配置解析实时凭据，Host 内出网，前端不拿 Key。
    final omniCallService = OmniRealtimeCallService(
      gateway: effectiveProviderSettings.omniRealtimeGateway ??
          QwenOmniRealtimeGateway(
            const DartIoProviderWebSocketConnector(),
            diagnosticsSink: diagnosticsSink,
          ),
      providerSettings: effectiveProviderSettings,
      repository: memoryRepository,
      memory: chatMemoryModule,
      actionExecutor: HiddenActionExecutor(
        memory: chatMemoryModule,
        aliasClient: effectiveProviderSettings,
        diagnosticsSink: diagnosticsSink ?? stderrDiagnostics,
      ),
      modelPromptBuilder: modelPromptBuilder,
      clock: clock,
      diagnosticsSink: diagnosticsSink,
    );
    // 启动节奏链由组合根直调（ticket 22 / ADR 0002）：仓库初始化之后
    // 恢复扫描→补日终→补月压缩→补 Dream，全部挂后台任务链，绝不
    // 阻塞首个可见回应。
    memoryCadence.initialize();
    // 四区记忆中心（ticket 19）：只依赖各存储的只读接口，不持有
    // 模型客户端与任何写入器；浏览与证据展开不触发模型调用、重新
    // 整理或隐式写入。写入动作归 memoryActions（ticket 20）。
    final memoryCenter = MemoryCenterService(
      memoryDirectory: memoryDirectory,
      episodePipeline: episodePipeline,
      personaTree: personaTree,
      memoryControls: memoryControls,
      dreamService: dreamService,
      memoryRecovery: memoryRecovery,
      clock: clock,
    );
    final onboardingRepository = JsonOnboardingRepository(
      filePath: path.join(runtimeDirectory, 'onboarding.json'),
    );
    // 开发者诊断快照服务：只读汇总最近请求、后台整理、Dream 资格与
    // 文件健康度；仅在体验选项开启开发者模式时经 /api/dev/diagnostics 暴露。
    final developerDiagnostics = DeveloperDiagnosticsService(
      memoryDirectory: memoryDirectory,
      recorder: requestDiagnostics,
      repository: memoryRepository,
      episodePipeline: episodePipeline,
      dreamService: dreamService,
      memoryControls: memoryControls,
      personaTree: personaTree,
      memoryRecovery: memoryRecovery,
      providerConfiguredReader: () async =>
          (await effectiveProviderSettings.read()).configured,
      clock: clock,
    );
    // 本机数据管理：数据位置概览与「清除产品数据」（清除前先落快照）。
    final localDataService = LocalDataService(
      memoryDirectory: memoryDirectory,
      repository: memoryRepository,
      backupService: memoryBackup,
      providerSettingsService: effectiveProviderSettings,
      webSearchSettingsService: effectiveWebSearchSettings,
      onboardingFilePath: path.join(runtimeDirectory, 'onboarding.json'),
      episodePipeline: episodePipeline,
      memoryControls: memoryControls,
    );
    // 六领域路由在组合根一次装配完毕，集合顺序即分发优先级：聊天、记忆、
    // 设置、备份、语音、引导。请求入口只消费这份已装配好的有序集合，
    // 不再认识任何具体领域对象；调整某个领域的构造依赖不必再改安全入口。
    final apiRoutes = <ApiRoutes>[
      ChatRoutes(chatService: chatService),
      // Omni 双工通话（T03）：与聊天并列入有序集合，鉴权前置于总控。
      OmniCallRoutes(callService: omniCallService),
      MemoryRoutes(
        memoryCenter: memoryCenter,
        memoryActions: memoryActions,
        memoryControls: memoryControls,
        personaTree: personaTree,
        memoryCadence: memoryCadence,
        // 票 04：记忆中心来源/控制动作成功后调度召回索引的增量同步
        //（组合根唯一实例）。
        embeddingRecall: effectiveEpisodeRag,
      ),
      SettingsRoutes(
        providerSettingsService: effectiveProviderSettings,
        webSearchSettingsService: effectiveWebSearchSettings,
        proxySettingsService: proxySettingsService,
        sttSettingsService: effectiveSttSettings,
        ttsSettingsService: effectiveTtsSettings,
        embeddingSettingsService: effectiveEmbeddingSettings,
        episodeRagService: effectiveEpisodeRag,
        experienceRepository: experienceRepository,
        developerDiagnostics: developerDiagnostics,
        requestDiagnostics: requestDiagnostics,
      ),
      BackupRoutes(
        memoryBackup: memoryBackup,
        localDataService: localDataService,
        chatService: chatService,
      ),
      VoiceRoutes(
        sttSettingsService: effectiveSttSettings,
        ttsSettingsService: effectiveTtsSettings,
        memoryRepository: memoryRepository,
      ),
      OnboardingRoutes(
        onboardingRepository: onboardingRepository,
        personaTree: personaTree,
      ),
    ];
    final requestHandler = _LocalAppRequestHandler(
      webRoot,
      apiRoutes,
      activationToken: activationToken,
      onActivate: onActivate,
    );
    final handler = const Pipeline()
        .addMiddleware(_securityHeaders())
        .addHandler(requestHandler.call);
    final server = await shelf_io.serve(
      handler,
      InternetAddress.loopbackIPv4,
      0,
      shared: false,
    );
    requestHandler.attach(
      Uri(scheme: 'http', host: server.address.address, port: server.port),
    );
    // 空闲补办轮询（spec）：初始化完成后启动周期定时器壳；注入 null
    // 时用生产默认（每 10 分钟拨一次 tick），测试可注入替身观察收尾。
    final catchupPoller =
        idleCatchupPoller ?? PeriodicIdleCatchupPoller(memoryCadence.pollTick);
    catchupPoller.start();
    return LocalAppHost._(
      server,
      requestHandler,
      catchupPoller,
      memoryCadence,
      chatService,
    );
  }

  /// 关闭前先停掉空闲补办轮询定时器（不再产生新 tick），再等待后台
  /// 日终归档、召回检索与索引任务收尾（票 05：Host 关闭排空既有索引
  /// 任务，不留下延迟发布）；归档幂等且每步原子写入，超时或失败不
  /// 阻塞关闭，未完成的归档由下次启动补扫继续，未完成的召回只是失去
  /// 一次「晚一拍想起」，不丢记忆。
  Future<void> close() async {
    _idleCatchupPoller.stop();
    try {
      await Future.wait<void>([
        _memoryCadence.finalizePending(),
        _chatService.settlePendingRecalls(),
        // 票 05：等在途索引构建/增量同步推进到安全点（批次边界或完成），
        // 关闭后不会有延迟发布再写缓存文件。
        _chatService.settlePendingIndexWork(),
      ]).timeout(const Duration(seconds: 3));
    } on Object {
      // 归档中断安全：finalized 保持 false，启动补扫会重做。
    }
    await _server.close(force: true);
  }
}

final class _LocalAppRequestHandler {
  /// 安全与分发入口：只认识静态资源根、组合根装配好的有序路由集合，
  /// 以及启动/激活凭据与回调。凭据生成、Origin attach、会话与 CSRF
  /// 检查都在本类内，领域对象的构造依赖与本类无关。
  _LocalAppRequestHandler(
    String webRoot,
    List<ApiRoutes> apiRoutes, {
    required this.activationToken,
    required this.onActivate,
  }) : _startupToken = generateSecureToken(),
       _sessionToken = generateSecureToken(),
       _csrfToken = generateSecureToken(),
       _staticHandler = createStaticHandler(
         webRoot,
         defaultDocument: 'index.html',
         listDirectories: false,
       ),
       _apiRoutes = apiRoutes;

  String _startupToken;
  String get startupToken => _startupToken;
  final String? activationToken;
  final Future<BrowserLaunchResult> Function()? onActivate;
  final String _sessionToken;
  final String _csrfToken;
  final Handler _staticHandler;
  final List<ApiRoutes> _apiRoutes;
  Uri? _origin;

  void attach(Uri origin) {
    if (_origin != null) {
      throw StateError('Local app request handler is already attached');
    }
    _origin = origin;
  }

  FutureOr<Response> call(Request request) {
    final origin = _origin;
    if (origin == null) {
      return plainError(HttpStatus.serviceUnavailable, 'Host is starting');
    }

    if (!_hasExpectedHost(request, origin)) {
      return plainError(HttpStatus.forbidden, 'Unexpected Host');
    }

    if (request.url.path == '_session/start') {
      return _startSession(request);
    }

    if (request.url.path == '_instance/activate') {
      return _activateInstance(request, origin);
    }

    if (request.url.path.startsWith('api/')) {
      return _handleApi(request, origin);
    }

    return _staticHandler(request);
  }

  Response _startSession(Request request) {
    if (request.method != 'GET' ||
        request.url.queryParameters['token'] != _startupToken) {
      return plainError(HttpStatus.unauthorized, 'Invalid startup credential');
    }

    // 兑换成功后立即轮换，登录 URL 只能使用一次。
    _startupToken = generateSecureToken();

    return Response(
      HttpStatus.seeOther,
      headers: {
        HttpHeaders.locationHeader: '/',
        HttpHeaders.setCookieHeader:
            '$_sessionCookieName=$_sessionToken; Path=/; HttpOnly; SameSite=Strict',
        HttpHeaders.cacheControlHeader: 'no-store',
      },
    );
  }

  Future<Response> _activateInstance(Request request, Uri origin) async {
    final expectedToken = activationToken;
    final activate = onActivate;
    if (request.method != 'POST' ||
        expectedToken == null ||
        activate == null ||
        request.headers['x-qiyu-activation'] != expectedToken) {
      return plainError(HttpStatus.forbidden, 'Invalid activation request');
    }
    final result = await activate();
    if (result.succeeded) {
      return Response(HttpStatus.noContent, headers: noStoreHeaders);
    }
    final displayUrl = origin.replace(
      path: '/_session/start',
      queryParameters: {'token': _startupToken},
    );
    return Response(
      HttpStatus.serviceUnavailable,
      body: jsonEncode({'displayUrl': displayUrl.toString()}),
      headers: jsonHeaders,
    );
  }

  Future<Response> _handleApi(Request request, Uri origin) async {
    final modifying = request.method != 'GET' && request.method != 'HEAD';
    if (!_hasExpectedSource(request, origin, requireOrigin: modifying)) {
      return plainError(HttpStatus.forbidden, 'Unexpected request source');
    }
    if (!_hasSession(request)) {
      return plainError(HttpStatus.unauthorized, 'Invalid session');
    }
    if (modifying && request.headers[_csrfHeaderName] != _csrfToken) {
      return plainError(HttpStatus.forbidden, 'Invalid CSRF token');
    }

    if (request.method == 'GET' && request.url.path == 'api/bootstrap') {
      return Response.ok(
        jsonEncode({
          'csrfToken': _csrfToken,
          'session': 'active',
          'host': origin.host,
          'port': origin.port,
        }),
        headers: jsonHeaders,
      );
    }
    if (request.method == 'GET' && request.url.path == 'api/health') {
      return Response.ok(jsonEncode({'status': 'ok'}), headers: jsonHeaders);
    }
    if (request.method == 'POST' && request.url.path == 'api/session/verify') {
      return Response(HttpStatus.noContent, headers: noStoreHeaders);
    }

    // 会话前置之后的请求交给领域路由模块；谁都不认领即按不存在处理。
    for (final routes in _apiRoutes) {
      final response = await routes.handle(request);
      if (response != null) {
        return response;
      }
    }
    return plainError(HttpStatus.notFound, 'Not found');
  }

  bool _hasExpectedHost(Request request, Uri origin) {
    return request.headers[HttpHeaders.hostHeader] ==
        '${origin.host}:${origin.port}';
  }

  bool _hasExpectedSource(
    Request request,
    Uri origin, {
    required bool requireOrigin,
  }) {
    final sourceOrigin = request.headers['origin'];
    final referer = request.headers[HttpHeaders.refererHeader];
    if (requireOrigin && sourceOrigin == null) {
      return false;
    }
    if (sourceOrigin != null && !_sameOrigin(sourceOrigin, origin)) {
      return false;
    }
    if (referer != null && !_sameOrigin(referer, origin)) {
      return false;
    }
    return true;
  }

  bool _hasSession(Request request) {
    final cookieHeader = request.headers[HttpHeaders.cookieHeader];
    if (cookieHeader == null) {
      return false;
    }
    for (final part in cookieHeader.split(';')) {
      final segments = part.trim().split('=');
      if (segments.length >= 2 &&
          segments.first == _sessionCookieName &&
          segments.sublist(1).join('=') == _sessionToken) {
        return true;
      }
    }
    return false;
  }
}

bool _sameOrigin(String value, Uri expected) {
  final candidate = Uri.tryParse(value);
  if (candidate == null || !candidate.hasScheme || candidate.host.isEmpty) {
    return false;
  }
  return candidate.scheme == expected.scheme &&
      candidate.host == expected.host &&
      candidate.port == expected.port;
}

/// 内存易失凭据仓：壳未注入平台凭据实现时 [LocalAppHost.start] 的
/// 缺省（组合根测试与未配置场景）。Key 只存本实例内存，不落盘、
/// 不出进程；生产壳必须注入平台凭据仓实现。
final class _VolatileSecretStore implements SecretStore {
  final _values = <String, String>{};

  @override
  Future<String?> readApiKey(String scope) async => _values[scope];

  @override
  Future<void> deleteApiKey(String scope) async {
    _values.remove(scope);
  }
}

Middleware _securityHeaders() {
  return createMiddleware(
    responseHandler: (response) => response.change(
      headers: {
        'content-security-policy':
            "default-src 'self'; connect-src 'self'; img-src 'self' data:; "
            "font-src 'self'; style-src 'self' 'unsafe-inline'; "
            "script-src 'self' 'wasm-unsafe-eval' blob:; "
            "worker-src 'self' blob:; frame-ancestors 'none'",
        'x-frame-options': 'DENY',
        'referrer-policy': 'same-origin',
        'x-content-type-options': 'nosniff',
      },
    ),
  );
}
