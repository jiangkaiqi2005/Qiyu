import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';
import 'package:path/path.dart' as path;

import 'browser_launcher.dart';
import 'daily_finalization.dart';
import 'dream.dart';
import 'episode_memory.dart';
import 'local_chat_service.dart';
import 'markdown_memory_repository.dart';
import 'memory_actions.dart';
import 'memory_backup.dart';
import 'memory_center.dart';
import 'memory_controls.dart';
import 'memory_recall.dart';
import 'memory_recovery.dart';
import 'model_gateway.dart';
import 'model_prompt_builder.dart';
import 'monthly_summary.dart';
import 'onboarding_state.dart';
import 'open_loop_store.dart';
import 'persona_tree.dart';
import 'provider_config.dart';
import 'provider_settings_service.dart';
import 'relationship_lifecycle.dart';
import 'secure_token.dart';
import 'secret_store.dart';
import 'state_pack_reader.dart';

const _sessionCookieName = 'qiyu_session';
const _csrfHeaderName = 'x-qiyu-csrf';

final class LocalAppHost {
  LocalAppHost._(this._server, this._requestHandler);

  final HttpServer _server;
  final _LocalAppRequestHandler _requestHandler;

  InternetAddress get address => _server.address;

  int get port => _server.port;

  Uri get origin => Uri(scheme: 'http', host: address.address, port: port);

  Uri get launchUri => origin.replace(
    path: '/_session/start',
    queryParameters: {'token': _requestHandler.startupToken},
  );

  static Future<LocalAppHost> start({
    required String webRoot,
    required String memoryDirectory,
    required String personaConstitution,
    String? activationToken,
    Future<BrowserLaunchResult> Function()? onActivate,
    ProviderSettingsService? providerSettingsService,
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
    final effectiveProviderSettings =
        providerSettingsService ??
        ProviderSettingsService(
          JsonProviderConfigRepository(
            filePath: path.join(
              Directory(memoryDirectory).parent.path,
              'provider.json',
            ),
          ),
          const WindowsCredentialSecretStore(),
          const ProviderModelGateway(DartIoProviderHttpClient()),
          modelPromptBuilder,
        );
    final episodePipeline = EpisodeMemoryPipeline(
      memoryDirectory: memoryDirectory,
    );
    // 用户记忆控制记录的唯一读写者（ticket 18）：Open-loop 热层与
    // 聊天即时生效两条路径共享同一实例，避免双写覆盖。
    final memoryControls = MemoryControlsStore(
      memoryDirectory: memoryDirectory,
    );
    // Open-loop 生命周期由日终归档与对话即时生效两条路径共享同一存储。
    final openLoopStore = OpenLoopStore(
      memoryDirectory: memoryDirectory,
      memoryControls: memoryControls,
    );
    // 关系生命周期由日终归档与删除即时清除共享同一实例。
    final relationshipLifecycle = RelationshipLifecycle(
      memoryDirectory: memoryDirectory,
    );
    // PersonaTree 同样由随手记建叶与日终整理两条路径共享同一实例：
    // 树文件串行锁在实例内部，必须唯一。
    final personaTree = PersonaTreeStore(
      memoryDirectory: memoryDirectory,
      episodePipeline: episodePipeline,
      openLoopStore: openLoopStore,
    );
    // 月压缩由后台任务链触发（五段节奏第四动作），共享同一实例。
    final monthlySummary = MonthlySummaryStore(
      memoryDirectory: memoryDirectory,
      episodePipeline: episodePipeline,
      openLoopStore: openLoopStore,
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
    );
    final chatService = LocalChatService(
      MarkdownMemoryRepository(memoryDirectory: memoryDirectory),
      providerChatClient: effectiveProviderSettings,
      modelPromptBuilder: modelPromptBuilder,
      episodePipeline: episodePipeline,
      dailyFinalization: DailyFinalizationService(
        memoryDirectory: memoryDirectory,
        episodePipeline: episodePipeline,
        openLoopStore: openLoopStore,
        personaTree: personaTree,
        relationshipLifecycle: relationshipLifecycle,
        // 日终一次模型理解调用与聊天共用同一 Provider 配置与凭据；
        // 未配置时日终自动走全确定性路径。
        modelClient: effectiveProviderSettings,
      ),
      openLoopStore: openLoopStore,
      statePackReader: StatePackReader(
        memoryDirectory: memoryDirectory,
        openLoopStore: openLoopStore,
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
      monthlySummary: monthlySummary,
      dreamService: dreamService,
      memoryControls: memoryControls,
      relationshipLifecycle: relationshipLifecycle,
      memoryActions: memoryActions,
      memoryRecovery: memoryRecovery,
    );
    await chatService.initialize();
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
    );
    final onboardingRepository = JsonOnboardingRepository(
      filePath: path.join(
        Directory(memoryDirectory).parent.path,
        'onboarding.json',
      ),
    );
    final requestHandler = _LocalAppRequestHandler(
      webRoot,
      chatService: chatService,
      providerSettingsService: effectiveProviderSettings,
      onboardingRepository: onboardingRepository,
      memoryCenter: memoryCenter,
      memoryActions: memoryActions,
      memoryBackup: memoryBackup,
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
    return LocalAppHost._(server, requestHandler);
  }

  /// 关闭前先等待后台日终归档与召回检索收尾；归档幂等且每步原子
  /// 写入，超时或失败不阻塞关闭，未完成的归档由下次启动补扫继续，
  /// 未完成的召回只是失去一次「晚一拍想起」，不丢记忆。
  Future<void> close() async {
    try {
      final service = _requestHandler.chatService;
      await Future.wait<void>([
        service.finalizePending(),
        service.settlePendingRecalls(),
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
    required this.onboardingRepository,
    required this.memoryCenter,
    required this.memoryActions,
    required this.memoryBackup,
    required this.activationToken,
    required this.onActivate,
  }) : _startupToken = generateSecureToken(),
       _sessionToken = generateSecureToken(),
       _csrfToken = generateSecureToken(),
       _staticHandler = createStaticHandler(
         webRoot,
         defaultDocument: 'index.html',
         listDirectories: false,
       );

  String _startupToken;
  String get startupToken => _startupToken;
  final LocalChatService chatService;
  final ProviderSettingsService providerSettingsService;
  final OnboardingRepository onboardingRepository;
  final MemoryCenterService memoryCenter;
  final MemoryActionService memoryActions;
  final MemoryBackupService memoryBackup;
  final String? activationToken;
  final Future<BrowserLaunchResult> Function()? onActivate;
  final String _sessionToken;
  final String _csrfToken;
  final Handler _staticHandler;
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
      return _plainError(HttpStatus.serviceUnavailable, 'Host is starting');
    }

    if (!_hasExpectedHost(request, origin)) {
      return _plainError(HttpStatus.forbidden, 'Unexpected Host');
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
      return _plainError(HttpStatus.unauthorized, 'Invalid startup credential');
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
      return _plainError(HttpStatus.forbidden, 'Invalid activation request');
    }
    final result = await activate();
    if (result.succeeded) {
      return Response(HttpStatus.noContent, headers: _noStoreHeaders);
    }
    final displayUrl = origin.replace(
      path: '/_session/start',
      queryParameters: {'token': _startupToken},
    );
    return Response(
      HttpStatus.serviceUnavailable,
      body: jsonEncode({'displayUrl': displayUrl.toString()}),
      headers: _jsonHeaders,
    );
  }

  Future<Response> _handleApi(Request request, Uri origin) async {
    final modifying = request.method != 'GET' && request.method != 'HEAD';
    if (!_hasExpectedSource(request, origin, requireOrigin: modifying)) {
      return _plainError(HttpStatus.forbidden, 'Unexpected request source');
    }
    if (!_hasSession(request)) {
      return _plainError(HttpStatus.unauthorized, 'Invalid session');
    }
    if (modifying && request.headers[_csrfHeaderName] != _csrfToken) {
      return _plainError(HttpStatus.forbidden, 'Invalid CSRF token');
    }

    if (request.method == 'GET' && request.url.path == 'api/bootstrap') {
      return Response.ok(
        jsonEncode({
          'csrfToken': _csrfToken,
          'session': 'active',
          'host': origin.host,
          'port': origin.port,
        }),
        headers: _jsonHeaders,
      );
    }
    if (request.method == 'GET' && request.url.path == 'api/health') {
      return Response.ok(jsonEncode({'status': 'ok'}), headers: _jsonHeaders);
    }
    if (request.method == 'POST' && request.url.path == 'api/session/verify') {
      return Response(HttpStatus.noContent, headers: _noStoreHeaders);
    }
    try {
      if (request.method == 'GET' && request.url.path == 'api/onboarding') {
        final state = await onboardingRepository.load();
        return Response.ok(
          jsonEncode({'completed': state.completed}),
          headers: _jsonHeaders,
        );
      }
      if (request.method == 'POST' &&
          request.url.path == 'api/onboarding/complete') {
        final state = await onboardingRepository.markCompleted(DateTime.now());
        return Response.ok(
          jsonEncode({'completed': state.completed}),
          headers: _jsonHeaders,
        );
      }
      if (request.method == 'GET' && request.url.path == 'api/provider') {
        final settings = await providerSettingsService.read();
        return Response.ok(
          jsonEncode(settings.toJson()),
          headers: _jsonHeaders,
        );
      }
      if (request.method == 'PUT' && request.url.path == 'api/provider') {
        final payload = await _readJsonObject(request, maxBytes: 32 * 1024);
        final config = _providerConfigFromPayload(payload);
        final apiKey = payload['apiKey'];
        if (apiKey != null && apiKey is! String) {
          throw const ProviderConfigException('API Key 格式不正确。');
        }
        final settings = await providerSettingsService.save(
          config: config,
          apiKey: apiKey as String?,
        );
        return Response.ok(
          jsonEncode(settings.toJson()),
          headers: _jsonHeaders,
        );
      }
      if (request.method == 'POST' && request.url.path == 'api/provider/test') {
        final payload = await _readJsonObject(request, maxBytes: 32 * 1024);
        final apiKey = payload['apiKey'];
        if (apiKey != null && apiKey is! String) {
          throw const ProviderConfigException('API Key 格式不正确。');
        }
        final config = payload.isEmpty
            ? (await providerSettingsService.read()).config
            : _providerConfigFromPayload(payload);
        if (config == null) {
          const result = ProviderTestResult(
            status: ProviderTestStatus.notConfigured,
            message: '还没有保存模型配置。',
          );
          return Response.ok(
            jsonEncode(result.toJson()),
            headers: _jsonHeaders,
          );
        }
        final result = await providerSettingsService.test(
          config: config,
          apiKey: apiKey as String?,
        );
        return Response.ok(jsonEncode(result.toJson()), headers: _jsonHeaders);
      }
      if (request.method == 'DELETE' &&
          request.url.path == 'api/provider/key') {
        final settings = await providerSettingsService.forgetApiKey();
        return Response.ok(
          jsonEncode(settings.toJson()),
          headers: _jsonHeaders,
        );
      }
      if (request.method == 'GET' && request.url.path == 'api/chat/session') {
        final snapshot = await chatService.restore(
          sessionId: request.url.queryParameters['sessionId'],
        );
        return Response.ok(
          jsonEncode(snapshot.toJson()),
          headers: _jsonHeaders,
        );
      }
      if (request.method == 'GET' && request.url.path == 'api/history') {
        final listing = await chatService.history();
        return Response.ok(
          jsonEncode(_historyJson(listing)),
          headers: _jsonHeaders,
        );
      }
      if (request.method == 'DELETE' &&
          request.url.path.startsWith('api/history/sessions/')) {
        final sessionId = request.url.path.substring(
          'api/history/sessions/'.length,
        );
        if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(sessionId)) {
          throw const LocalChatException(
            code: 'invalid_request',
            message: '会话标识格式不正确。',
            retryable: false,
          );
        }
        await chatService.deleteSession(sessionId);
        return Response.ok(
          jsonEncode({'deleted': true}),
          headers: _jsonHeaders,
        );
      }
      if (request.method == 'GET' && request.url.path == 'api/memory') {
        final overview = await memoryCenter.overview();
        return Response.ok(
          jsonEncode(overview.toJson()),
          headers: _jsonHeaders,
        );
      }
      if (request.method == 'GET' &&
          request.url.path.startsWith('api/memory/items/')) {
        final itemId = request.url.path.substring('api/memory/items/'.length);
        if (itemId.isEmpty || itemId.contains('/')) {
          throw const LocalChatException(
            code: 'invalid_request',
            message: '记忆条目标识格式不正确。',
            retryable: false,
          );
        }
        final detail = await memoryCenter.itemDetail(itemId);
        if (detail == null) {
          return _jsonError(
            HttpStatus.notFound,
            code: 'memory_item_not_found',
            message: '这条记忆不存在或已经变化，请返回后刷新。',
            retryable: false,
          );
        }
        return Response.ok(jsonEncode(detail.toJson()), headers: _jsonHeaders);
      }
      if (request.method == 'POST' && request.url.path == 'api/memory/action') {
        final Map<String, Object?> payload;
        try {
          payload = await _readJsonObject(request, maxBytes: 16 * 1024);
        } on FormatException {
          throw const LocalChatException(
            code: 'invalid_request',
            message: '记忆操作请求格式不正确。',
            retryable: false,
          );
        }
        final action = payload['action'];
        final id = payload['id'];
        if (action is! String ||
            action.isEmpty ||
            id is! String ||
            id.isEmpty) {
          throw const LocalChatException(
            code: 'invalid_request',
            message: '记忆操作请求格式不正确。',
            retryable: false,
          );
        }
        final ref = memoryCenter.resolveRef(id);
        if (ref == null) {
          return _jsonError(
            HttpStatus.notFound,
            code: 'memory_item_not_found',
            message: '这条记忆不存在或已经变化，请返回后刷新。',
            retryable: false,
          );
        }
        final MemoryActionResult result;
        switch (action) {
          case 'edit':
            final text = payload['text'];
            if (text is! String) {
              throw const LocalChatException(
                code: 'invalid_request',
                message: '记忆操作请求格式不正确。',
                retryable: false,
              );
            }
            result = await memoryActions.edit(ref, text);
          case 'freeze':
            result = await memoryActions.freeze(ref);
          case 'unfreeze':
            result = await memoryActions.unfreeze(ref);
          case 'ban':
            result = await memoryActions.ban(ref);
          case 'unban':
            result = await memoryActions.unban(ref);
          case 'delete-preview':
            final impact = await memoryActions.deletePreview(ref);
            if (impact == null) {
              return _jsonError(
                HttpStatus.notFound,
                code: 'memory_item_not_found',
                message: '这条记忆不存在或已经变化，请返回后刷新。',
                retryable: false,
              );
            }
            return Response.ok(
              jsonEncode(impact.toJson()),
              headers: _jsonHeaders,
            );
          case 'delete':
            result = await memoryActions.delete(ref);
          case 'reveal':
            final field = payload['field'];
            result = await memoryActions.reveal(
              ref,
              field is String && field.isNotEmpty ? field : 'content',
            );
          default:
            throw const LocalChatException(
              code: 'invalid_request',
              message: '不支持的记忆操作。',
              retryable: false,
            );
        }
        final statusCode = switch (result.code) {
          'memory_item_not_found' => HttpStatus.notFound,
          'memory_action_not_allowed' ||
          'memory_item_not_masked' ||
          'memory_delete_no_target' => HttpStatus.badRequest,
          _ => HttpStatus.ok,
        };
        return Response(
          statusCode,
          body: jsonEncode(result.toJson()),
          headers: _jsonHeaders,
        );
      }
      if (request.method == 'GET' && request.url.path == 'api/backup/export') {
        final export = await memoryBackup.exportBundle();
        return Response.ok(
          export.bytes,
          headers: {
            HttpHeaders.contentTypeHeader: 'application/zip',
            'content-disposition':
                'attachment; filename="${export.fileName}"',
            HttpHeaders.cacheControlHeader: 'no-store',
          },
        );
      }
      if (request.method == 'POST' &&
          request.url.path == 'api/backup/preview') {
        final bundle = await _readBackupBundle(request);
        final preview = await memoryBackup.previewImport(bundle);
        return Response.ok(
          jsonEncode(preview.toJson()),
          headers: _jsonHeaders,
        );
      }
      if (request.method == 'POST' &&
          request.url.path == 'api/backup/import') {
        final bundle = await _readBackupBundle(request);
        final result = await memoryBackup.importBundle(bundle);
        return Response.ok(
          jsonEncode(result.toJson()),
          headers: _jsonHeaders,
        );
      }
      if (request.method == 'GET' &&
          request.url.path == 'api/backup/snapshots') {
        final snapshots = await memoryBackup.listSnapshots();
        return Response.ok(
          jsonEncode({
            'snapshots': [
              for (final snapshot in snapshots) snapshot.toJson(),
            ],
          }),
          headers: _jsonHeaders,
        );
      }
      if (request.method == 'POST' &&
          request.url.path == 'api/backup/rollback') {
        final payload = await _readJsonObject(request, maxBytes: 4 * 1024);
        final snapshotId = payload['snapshotId'];
        if (snapshotId != null && snapshotId is! String) {
          throw const LocalChatException(
            code: 'invalid_request',
            message: '回滚请求格式不正确。',
            retryable: false,
          );
        }
        final result = await memoryBackup.rollbackTo(snapshotId as String?);
        return Response.ok(
          jsonEncode(result.toJson()),
          headers: _jsonHeaders,
        );
      }
      if (request.method == 'POST' && request.url.path == 'api/chat/cancel') {
        final payload = await _readJsonObject(request, maxBytes: 4 * 1024);
        final requestId = payload['requestId'];
        if (requestId is! String || requestId.trim().isEmpty) {
          throw const LocalChatException(
            code: 'invalid_request',
            message: '聊天请求格式不正确。',
            retryable: false,
          );
        }
        return Response.ok(
          jsonEncode({'cancelled': chatService.cancel(requestId)}),
          headers: _jsonHeaders,
        );
      }
      if (request.method == 'POST' && request.url.path == 'api/chat') {
        final payload = await _readJsonObject(request, maxBytes: 64 * 1024);
        final requestId = payload['requestId'];
        final text = payload['text'];
        final sessionId = payload['sessionId'];
        if (requestId is! String ||
            text is! String ||
            (sessionId != null && sessionId is! String) ||
            requestId.trim().isEmpty ||
            text.trim().isEmpty) {
          throw const LocalChatException(
            code: 'invalid_request',
            message: '聊天请求格式不正确。',
            retryable: false,
          );
        }
        return Response.ok(
          chatService
              .deliver(
                requestId: requestId,
                text: text,
                sessionId: sessionId as String?,
              )
              .map((event) => utf8.encode('${jsonEncode(event.toJson())}\n')),
          headers: _streamHeaders,
        );
      }
    } on FormatException {
      return _jsonError(
        HttpStatus.badRequest,
        code: 'invalid_request',
        message: '聊天请求格式不正确。',
        retryable: false,
      );
    } on BackupValidationException catch (error) {
      return _jsonError(
        HttpStatus.badRequest,
        code: error.code,
        message: error.message,
        retryable: false,
      );
    } on LocalChatException catch (error) {
      final status = switch (error.code) {
        'invalid_request' => HttpStatus.badRequest,
        'request_id_conflict' => HttpStatus.conflict,
        _ => HttpStatus.internalServerError,
      };
      return _jsonError(
        status,
        code: error.code,
        message: error.message,
        retryable: error.retryable,
      );
    } on ProviderConfigException catch (error) {
      return _jsonError(
        HttpStatus.badRequest,
        code: 'invalid_provider_config',
        message: error.message,
        retryable: false,
      );
    } on SecretStoreException catch (error) {
      return _jsonError(
        HttpStatus.internalServerError,
        code: 'credential_store_error',
        message: error.message,
        retryable: true,
      );
    } on OnboardingStateException catch (error) {
      return _jsonError(
        HttpStatus.internalServerError,
        code: 'onboarding_unavailable',
        message: error.message,
        retryable: true,
      );
    } on MemoryRepositoryException catch (error) {
      final status = error.code == 'session_not_found'
          ? HttpStatus.notFound
          : HttpStatus.internalServerError;
      return _jsonError(
        status,
        code: error.code,
        message: error.message,
        retryable: error.retryable,
      );
    }
    return _plainError(HttpStatus.notFound, 'Not found');
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

/// 备份请求体上限：base64 编码后的 zip。本机记忆是纯文本，正常备份
/// 远小于该值；超限直接拒绝，不进入验证与写入。
const _backupBundleMaxBytes = 96 * 1024 * 1024;

Future<Uint8List> _readBackupBundle(Request request) async {
  final payload = await _readJsonObject(
    request,
    maxBytes: _backupBundleMaxBytes,
  );
  final data = payload['dataBase64'];
  if (data is! String || data.isEmpty) {
    throw const LocalChatException(
      code: 'invalid_request',
      message: '备份请求格式不正确。',
      retryable: false,
    );
  }
  try {
    return base64.decode(data);
  } on Object {
    throw const LocalChatException(
      code: 'invalid_request',
      message: '备份文件读不出来，请重新选择。',
      retryable: false,
    );
  }
}

Future<Map<String, Object?>> _readJsonObject(
  Request request, {
  required int maxBytes,
}) async {
  final contentLength = request.contentLength;
  if (contentLength != null && contentLength > maxBytes) {
    throw const FormatException('request body is too large');
  }
  // 累计计数以覆盖无 Content-Length 的 chunked 请求体。
  final buffer = BytesBuilder(copy: false);
  var totalBytes = 0;
  await for (final chunk in request.read()) {
    totalBytes += chunk.length;
    if (totalBytes > maxBytes) {
      throw const FormatException('request body is too large');
    }
    buffer.add(chunk);
  }
  final decoded = jsonDecode(utf8.decode(buffer.takeBytes()));
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('request body must be an object');
  }
  return decoded;
}

Map<String, Object?> _historyJson(HistoryListing listing) {
  RawSession? latest;
  for (final session in listing.sessions) {
    if (latest == null || session.updatedAt.isAfter(latest.updatedAt)) {
      latest = session;
    }
  }
  final days = <Map<String, Object?>>[];
  for (final session in listing.sessions) {
    if (days.isEmpty || days.last['date'] != session.date) {
      days.add({'date': session.date, 'sessions': <Map<String, Object?>>[]});
    }
    final daySessions = days.last['sessions']! as List<Map<String, Object?>>;
    daySessions.add(_sessionSummaryJson(session));
  }
  return {
    'latestSessionId': ?latest?.id,
    'days': days,
    'unavailable': [
      for (final entry in listing.unavailable)
        {'name': entry.name, 'message': entry.message},
    ],
  };
}

Map<String, Object?> _sessionSummaryJson(RawSession session) {
  final startedAt = session.turns.isEmpty
      ? session.createdAt
      : session.turns.first.at;
  return {
    'sessionId': session.id,
    'segment': session.segment,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'updatedAt': session.updatedAt.toUtc().toIso8601String(),
    'turnCount': session.turns.length,
    'preview': _historyPreview(session),
  };
}

String _historyPreview(RawSession session) {
  if (session.turns.isEmpty) {
    return '';
  }
  final lines = session.turns.first.text.replaceAll('\r\n', '\n').split('\n');
  final firstLine = lines
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .firstOrNull;
  final runes = (firstLine ?? '').runes.toList(growable: false);
  if (runes.length <= 60) {
    return String.fromCharCodes(runes);
  }
  return '${String.fromCharCodes(runes.sublist(0, 60))}…';
}

ProviderConfig _providerConfigFromPayload(Map<String, Object?> payload) {
  final provider = payload['provider'];
  final baseUrl = payload['baseUrl'];
  final model = payload['model'];
  final temperature = payload['temperature'];
  final timeoutSeconds = payload['timeoutSeconds'];
  if (provider is! String ||
      baseUrl is! String ||
      model is! String ||
      temperature is! num ||
      timeoutSeconds is! int) {
    throw const ProviderConfigException('模型配置格式不正确。');
  }
  return ProviderConfig(
    kind: ProviderKind.fromWireName(provider),
    baseUrl: baseUrl,
    model: model,
    temperature: temperature.toDouble(),
    timeoutSeconds: timeoutSeconds,
  );
}

const _jsonHeaders = {
  HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
  HttpHeaders.cacheControlHeader: 'no-store',
};

const _streamHeaders = {
  HttpHeaders.contentTypeHeader: 'application/x-ndjson; charset=utf-8',
  HttpHeaders.cacheControlHeader: 'no-store',
  'x-accel-buffering': 'no',
};

const _noStoreHeaders = {HttpHeaders.cacheControlHeader: 'no-store'};

Response _plainError(int statusCode, String message) {
  return Response(
    statusCode,
    body: redactDiagnosticText(message),
    headers: {
      HttpHeaders.contentTypeHeader: 'text/plain; charset=utf-8',
      HttpHeaders.cacheControlHeader: 'no-store',
    },
  );
}

Response _jsonError(
  int statusCode, {
  required String code,
  required String message,
  required bool retryable,
}) {
  return Response(
    statusCode,
    body: jsonEncode({
      'code': code,
      'message': redactDiagnosticText(message),
      'retryable': retryable,
    }),
    headers: _jsonHeaders,
  );
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
