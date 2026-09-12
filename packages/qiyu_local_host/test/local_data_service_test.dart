import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;
  late String runtimeDirectory;
  late String memoryDirectory;
  late EpisodeMemoryPipeline pipeline;
  late MemoryControlsStore memoryControls;
  late PersonaTreeStore personaTree;
  late MemoryActionService actions;
  late MemoryBackupService backup;
  late MarkdownMemoryRepository repository;
  late _MemoryProviderConfigRepository configRepository;
  late _MemorySecretStore secretStore;
  late ProviderSettingsService providerSettings;
  late WebSearchSettingsService webSearchSettings;
  late LocalDataService service;
  late String onboardingFilePath;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-local-data-test-',
    );
    runtimeDirectory = temporaryDirectory.path;
    memoryDirectory = path.join(runtimeDirectory, 'memories');
    await Directory(memoryDirectory).create(recursive: true);
    pipeline = EpisodeMemoryPipeline(memoryDirectory: memoryDirectory);
    memoryControls = MemoryControlsStore(
      memoryDirectory: memoryDirectory,
      diagnosticsSink: (_) {},
    );
    final openLoopStore = OpenLoopStore(
      memoryDirectory: memoryDirectory,
      memoryControls: memoryControls,
    );
    personaTree = PersonaTreeStore(
      memoryDirectory: memoryDirectory,
      episodePipeline: pipeline,
      openLoopStore: openLoopStore,
      diagnosticsSink: (_) {},
    );
    actions = MemoryActionService(
      memoryDirectory: memoryDirectory,
      episodePipeline: pipeline,
      personaTree: personaTree,
      memoryControls: memoryControls,
      openLoopStore: openLoopStore,
      monthlySummary: MonthlySummaryStore(
        memoryDirectory: memoryDirectory,
        episodePipeline: pipeline,
        diagnosticsSink: (_) {},
      ),
      relationshipLifecycle: RelationshipLifecycle(
        memoryDirectory: memoryDirectory,
      ),
      diagnosticsSink: (_) {},
    );
    backup = MemoryBackupService(
      memoryDirectory: memoryDirectory,
      memoryControls: memoryControls,
      episodePipeline: pipeline,
      personaTree: personaTree,
      memoryActions: actions,
      diagnosticsSink: (_) {},
    );
    repository = MarkdownMemoryRepository(memoryDirectory: memoryDirectory);
    await repository.initialize();
    configRepository = _MemoryProviderConfigRepository();
    secretStore = _MemorySecretStore();
    providerSettings = ProviderSettingsService(
      configRepository,
      secretStore,
      const _UnusedModelGateway(),
      const ModelPromptBuilder(''),
    );
    webSearchSettings = WebSearchSettingsService(configRepository);
    onboardingFilePath = path.join(runtimeDirectory, 'onboarding.json');
    service = LocalDataService(
      memoryDirectory: memoryDirectory,
      repository: repository,
      backupService: backup,
      providerSettingsService: providerSettings,
      webSearchSettingsService: webSearchSettings,
      onboardingFilePath: onboardingFilePath,
      episodePipeline: pipeline,
      memoryControls: memoryControls,
    );
  });

  tearDown(() async {
    if (temporaryDirectory.existsSync()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  Future<void> seedProductData() async {
    final session = await repository.createSession();
    await repository.appendTurn(
      session,
      RawSessionTurn.user(
        requestId: 'req-1',
        text: '你好',
        at: DateTime(2026, 8, 18, 22),
      ),
    );
    await memoryControls.ban('一段不想再提的事');
    await memoryControls.freeze('一段先收起来的记忆');
    File(onboardingFilePath).writeAsStringSync('{"completed": true}');
  }

  test('clear preview reports accurate impact and data location', () async {
    await seedProductData();

    final preview = await service.clearPreview();

    expect(preview['memoryDirectory'], memoryDirectory);
    expect(preview['sessionCount'], 1);
    expect(preview['bannedCount'], 1);
    expect(preview['frozenCount'], 1);
    expect(preview['deletedCount'], 0);
    expect(preview['snapshotCount'], 0);
    expect(preview['providerConfigured'], isFalse);
    expect(preview['keySet'], isFalse);
  });

  test('clear snapshots first, wipes product data and web search key', () async {
    await seedProductData();
    final config = ProviderConfig(
      kind: ProviderKind.openAiCompatible,
      baseUrl: 'https://api.example.com/v1',
      model: 'test-model',
      temperature: 0.7,
      timeoutSeconds: 60,
    );
    await providerSettings.save(config: config, apiKey: 'sk-testkey1234567890ab');
    await webSearchSettings.save(apiKey: 'any-secret-value');

    final result = await service.clear();

    expect(result['cleared'], isTrue);
    // 清除前先落了快照：备份目录仍在且含一份快照。
    final snapshots = await backup.listSnapshots();
    expect(snapshots, hasLength(1));
    expect(result['snapshotId'], snapshots.single.id);
    // 产品数据清空：会话、控制记录全部消失。
    expect(
      Directory(path.join(memoryDirectory, 'sessions')).existsSync(),
      isFalse,
    );
    expect(
      File(path.join(memoryDirectory, 'memory-controls.md')).existsSync(),
      isFalse,
    );
    final history = await repository.readHistory();
    expect(history.sessions, isEmpty);
    // 首次见面状态一并清除。
    expect(File(onboardingFilePath).existsSync(), isFalse);
    // 聊天模型连接设置与 Key 原样保留；AnySearch Key 一并删除。
    expect((await providerSettings.read()).configured, isTrue);
    expect((await providerSettings.read()).keySet, isTrue);
    expect(configRepository.stored!.apiKey, 'sk-testkey1234567890ab');
    expect((await webSearchSettings.read()).keySet, isFalse);
    expect(configRepository.webSearch, isNull);
  });

  test('clear still succeeds when nothing was ever written', () async {
    final result = await service.clear();
    expect(result['cleared'], isTrue);
    expect(File(onboardingFilePath).existsSync(), isFalse);
  });
}

final class _MemoryProviderConfigRepository
    implements ProviderConfigRepository, WebSearchConfigRepository {
  ProviderConfig? stored;
  WebSearchConfig? webSearch;

  @override
  Future<ProviderConfig?> load() async => stored;

  @override
  Future<void> save(ProviderConfig config) async {
    stored = config;
  }

  @override
  Future<WebSearchConfig?> loadWebSearch() async => webSearch;

  @override
  Future<void> saveWebSearch(WebSearchConfig? config) async {
    webSearch = config;
  }

  @override
  Future<T> runTransaction<T>(Future<T> Function() action) => action();
}

final class _MemorySecretStore implements SecretStore {
  final Map<String, String> values = {};

  @override
  Future<void> deleteApiKey(String scope) async => values.remove(scope);

  @override
  Future<String?> readApiKey(String scope) async => values[scope];
}

final class _UnusedModelGateway implements ModelGateway {
  const _UnusedModelGateway();

  @override
  Future<String> complete({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
    int? maxTokens,
  }) {
    throw UnsupportedError('local data tests never call the model');
  }
}
