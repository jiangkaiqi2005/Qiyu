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
import 'chat_routes.dart';
import 'daily_finalization.dart';
import 'developer_diagnostics.dart';
import 'dream.dart';
import 'episode_memory.dart';
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
import 'onboarding_routes.dart';
import 'onboarding_state.dart';
import 'open_loop_store.dart';
import 'persona_tree.dart';
import 'provider_config.dart';
import 'provider_settings_service.dart';
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
  );

  final HttpServer _server;
  final _LocalAppRequestHandler _requestHandler;
  final IdleCatchupPoller _idleCatchupPoller;
  final MemoryCadence _memoryCadence;

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
    String? activationToken,
    Future<BrowserLaunchResult> Function()? onActivate,
    ProviderSettingsService? providerSettingsService,
    WebSearchSettingsService? webSearchSettingsService,
    SttSettingsService? sttSettingsService,
    TtsSettingsService? ttsSettingsService,
    // 时钟、原子写入、交付停顿与诊断出口沿用各组件既有的注入接缝，
    // 缺省全部走生产默认；测试由此在真路径上获得确定性。
    Clock? clock,
    AtomicTextWriter? atomicWriter,
    DeliveryPause? deliveryPause,
    RecallWindowWait? recallWindowWait,
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
    final modelPromptBuilder = ModelPromptBuilder(personaConstitution);
    final runtimeDirectory = Directory(memoryDirectory).parent.path;
    final providerConfigRepository = JsonProviderConfigRepository(
      filePath: path.join(runtimeDirectory, 'provider.json'),
    );
    const providerHttpClient = DartIoProviderHttpClient();
    final effectiveProviderSettings =
        providerSettingsService ??
        ProviderSettingsService(
          providerConfigRepository,
          const WindowsCredentialSecretStore(),
          const ProviderModelGateway(providerHttpClient),
          modelPromptBuilder,
          webSearchConfigRepository: providerConfigRepository,
          webSearchClient: const AnySearchClient(providerHttpClient),
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
    final effectiveTtsSettings =
        ttsSettingsService ??
        TtsSettingsService(
          providerConfigRepository,
          TtsModelGateway(DartIoProviderHttpClient()),
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
      atomicWriter: atomicWriter,
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
    // 与敏感揭示；聊天隐藏动作的删除管线共用同一实现。
    final memoryActions = MemoryActionService(
      memoryDirectory: memoryDirectory,
      episodePipeline: episodePipeline,
      personaTree: personaTree,
      memoryControls: memoryControls,
      openLoopStore: openLoopStore,
      monthlySummary: monthlySummary,
      relationshipLifecycle: relationshipLifecycle,
      atomicWriter: atomicWriter,
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
    final chatService = LocalChatService(
      memoryRepository,
      providerPort: effectiveProviderSettings,
      requestDiagnostics: requestDiagnostics,
      modelPromptBuilder: modelPromptBuilder,
      episodePipeline: episodePipeline,
      openLoopStore: openLoopStore,
      statePackReader: StatePackReader(
        memoryDirectory: memoryDirectory,
        openLoopStore: openLoopStore,
        clock: clock,
      ),
      memoryRecall: RecallOrchestrator(
        memoryDirectory: memoryDirectory,
        episodePipeline: episodePipeline,
        // 轮内查找的选择/组织小调用与聊天共用同一 Provider 配置与
        // 凭据；未配置时轮内循环静默跳过（不召回保持现状）。
        modelClient: effectiveProviderSettings,
        openLoopStore: openLoopStore,
      ),
      personaTree: personaTree,
      memoryControls: memoryControls,
      relationshipLifecycle: relationshipLifecycle,
      memoryActions: memoryActions,
      memoryCadence: memoryCadence,
      deliveryPause: deliveryPause,
      recallWindowWait: recallWindowWait,
      clock: clock,
      diagnosticsSink: diagnosticsSink,
    );
    wiredChatService = chatService;
    await chatService.initialize();
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
    final requestHandler = _LocalAppRequestHandler(
      webRoot,
      chatService: chatService,
      providerSettingsService: effectiveProviderSettings,
      webSearchSettingsService: effectiveWebSearchSettings,
      sttSettingsService: effectiveSttSettings,
      ttsSettingsService: effectiveTtsSettings,
      memoryRepository: memoryRepository,
      onboardingRepository: onboardingRepository,
      memoryCenter: memoryCenter,
      memoryActions: memoryActions,
      personaTree: personaTree,
      memoryBackup: memoryBackup,
      memoryControls: memoryControls,
      experienceRepository: experienceRepository,
      developerDiagnostics: developerDiagnostics,
      localDataService: localDataService,
      requestDiagnostics: requestDiagnostics,
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
    return LocalAppHost._(server, requestHandler, catchupPoller, memoryCadence);
  }

  /// 关闭前先停掉空闲补办轮询定时器（不再产生新 tick），再等待后台
  /// 日终归档与召回检索收尾；归档幂等且每步原子写入，超时或失败不
  /// 阻塞关闭，未完成的归档由下次启动补扫继续，未完成的召回只是失去
  /// 一次「晚一拍想起」，不丢记忆。
  Future<void> close() async {
    _idleCatchupPoller.stop();
    try {
      await Future.wait<void>([
        _memoryCadence.finalizePending(),
        _requestHandler.chatService.settlePendingRecalls(),
      ]).timeout(const Duration(seconds: 3));
    } on Object {
      // 归档中断安全：finalized 保持 false，启动补扫会重做。
    }
    await _server.close(force: true);
  }
}

final class _LocalAppRequestHandler {
  _LocalAppRequestHandler(
    String webRoot, {
    required this.chatService,
    required this.providerSettingsService,
    required this.webSearchSettingsService,
    required SttSettingsService sttSettingsService,
    required TtsSettingsService ttsSettingsService,
    required MemoryRepository memoryRepository,
    required OnboardingRepository onboardingRepository,
    required this.memoryCenter,
    required this.memoryActions,
    required PersonaTreeStore personaTree,
    required MemoryBackupService memoryBackup,
    required this.memoryControls,
    required this.experienceRepository,
    required this.developerDiagnostics,
    required LocalDataService localDataService,
    required this.requestDiagnostics,
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
       _apiRoutes = [
         ChatRoutes(chatService: chatService),
         MemoryRoutes(
           memoryCenter: memoryCenter,
           memoryActions: memoryActions,
           memoryControls: memoryControls,
           personaTree: personaTree,
         ),
         SettingsRoutes(
           providerSettingsService: providerSettingsService,
           webSearchSettingsService: webSearchSettingsService,
           sttSettingsService: sttSettingsService,
           ttsSettingsService: ttsSettingsService,
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
           sttSettingsService: sttSettingsService,
           ttsSettingsService: ttsSettingsService,
           memoryRepository: memoryRepository,
         ),
         OnboardingRoutes(
           onboardingRepository: onboardingRepository,
           personaTree: personaTree,
         ),
       ];

  String _startupToken;
  String get startupToken => _startupToken;
  final LocalChatService chatService;
  final ProviderSettingsService providerSettingsService;
  final WebSearchSettingsService webSearchSettingsService;

  final MemoryCenterService memoryCenter;
  final MemoryActionService memoryActions;
  final MemoryControlsStore memoryControls;
  final ExperienceSettingsRepository experienceRepository;
  final DeveloperDiagnosticsService developerDiagnostics;
  final RequestDiagnosticsRecorder? requestDiagnostics;
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

Middleware _securityHeaders() {
  return createMiddleware(
    responseHandler: (response) => response.change(
      headers: {
        'content-security-policy':
            "default-src 'self'; connect-src 'self'; img-src 'self' data:; "
            "font-src 'self'; style-src 'self' 'unsafe-inline'; "
            "script-src 'self' 'wasm-unsafe-eval'; "
            "worker-src 'self' blob:; frame-ancestors 'none'",
        'x-frame-options': 'DENY',
        'referrer-policy': 'same-origin',
        'x-content-type-options': 'nosniff',
      },
    ),
  );
}
