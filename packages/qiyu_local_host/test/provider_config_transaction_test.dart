import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

import 'support/failing_atomic_writer.dart';
import 'support/hooked_atomic_writer.dart';

/// 配置写入原子事务（ticket 03）：聊天、语音转写、语音合成、联网搜索
/// 与代理五类设置共用 provider.json，「读取现值 → 决定 Key 去留 → 写
/// 回 → 旧凭据清理」的完整流程必须经仓储的共享读改写事务串行执行，
/// 不能只验证单次 rename 的原子性。用例只走公共接口（服务与仓储），
/// 用钩子式原子写入器在写回点编排确定性交错；所有凭据都是明显的测
/// 试假值，文件只落在专用临时目录。
void main() {
  late Directory temp;
  late String filePath;

  // 交错编排：第 N 次写回到达钩子时挂起，等用例放行后落真实盘。
  // 两侧 Completer 都按需创建，先到先用。
  final arrivals = <int, Completer<void>>{};
  final releases = <int, Completer<void>>{};

  setUp(() async {
    arrivals.clear();
    releases.clear();
    temp = await Directory.systemTemp.createTemp('qiyu-config-tx-');
    filePath = '${temp.path}${Platform.pathSeparator}provider.json';
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  Future<void> written(int call) =>
      arrivals.putIfAbsent(call, () => Completer<void>()).future;

  void letThrough(int call) =>
      releases.putIfAbsent(call, () => Completer<void>()).complete();

  HookedAtomicWriter hookedWriter() => HookedAtomicWriter((call, _) async {
    arrivals.putIfAbsent(call, () => Completer<void>()).complete();
    await releases.putIfAbsent(call, () => Completer<void>()).future;
  });

  JsonProviderConfigRepository repository() => JsonProviderConfigRepository(
    filePath: filePath,
    writer: hookedWriter(),
  );

  Future<void> seedJson(
    Map<String, Object?> json,
  ) => File(
    filePath,
  ).writeAsString('${const JsonEncoder.withIndent('  ').convert(json)}\n');

  Future<Map<String, Object?>> storedJson() async =>
      jsonDecode(await File(filePath).readAsString()) as Map<String, Object?>;

  const chatA = ProviderConfig(
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'https://chat-a.example.com/v1',
    model: 'chat-model',
    temperature: 0.6,
    timeoutSeconds: 25,
  );
  const chatB = ProviderConfig(
    kind: ProviderKind.anthropic,
    baseUrl: 'https://chat-b.example.com/v1',
    model: 'chat-model-b',
    temperature: 0.6,
    timeoutSeconds: 25,
  );

  Map<String, Object?> chatJson([String? apiKey]) => {
    'provider': 'openai_compatible',
    'baseUrl': chatA.baseUrl,
    'model': 'chat-model',
    'temperature': 0.6,
    'timeoutSeconds': 25,
    'apiKey': ?apiKey,
  };

  ProviderSettingsService chatService(
    JsonProviderConfigRepository repo, [
    _MemorySecretStore? secrets,
  ]) => ProviderSettingsService(
    repo,
    secrets ?? _MemorySecretStore(),
    _UnusedModelGateway(),
    const ModelPromptBuilder('测试人格宪法'),
  );

  WebSearchSettingsService searchService(JsonProviderConfigRepository repo) =>
      WebSearchSettingsService(repo);

  SttSettingsService sttService(JsonProviderConfigRepository repo) =>
      SttSettingsService(repo, SttModelGateway(DartIoProviderHttpClient()));

  TtsSettingsService ttsService(JsonProviderConfigRepository repo) =>
      TtsSettingsService(repo, TtsModelGateway(DartIoProviderHttpClient()));

  ProxySettingsService proxyService(JsonProviderConfigRepository repo) =>
      ProxySettingsService(repo);

  test('遗忘聊天 Key 与联网搜索保存交错，旧 Key 不随旧文件复活', () async {
    await seedJson({
      ...chatJson('fake-chat-key-not-real'),
      'unknownKeeper': {'kept': true},
    });
    final repo = repository();
    final chat = chatService(repo);
    final search = searchService(repo);

    final forgetting = chat.forgetApiKey();
    await written(1); // 遗忘的写回已到达、尚未落盘
    final saving = search.save(apiKey: 'fake-search-key-not-real');
    letThrough(1);
    await forgetting;
    // 遗忘已完整落盘：此刻读不到 Key。
    expect((await repo.load())!.apiKey, isNull);
    await written(2); // 搜索保存的写回（必须排在遗忘完整结束之后）
    letThrough(2);
    await saving;

    final stored = await storedJson();
    // 交错之后：搜索 Key 落位、聊天 Key 不复活、未知段保留。
    expect(
      (stored['webSearch']! as Map<String, Object?>)['apiKey'],
      'fake-search-key-not-real',
    );
    expect((await repo.load())!.apiKey, isNull);
    expect(stored['unknownKeeper'], {'kept': true});
  });

  test('同作用域重存与遗忘凭据交错，锁外旧 Key 不写回', () async {
    await seedJson(chatJson('fake-chat-key-not-real'));
    final repo = repository();
    final chat = chatService(repo);

    final forgetting = chat.forgetApiKey();
    await written(1);
    // 同作用域重存、未输入新 Key：Key 去留必须以事务内现值为准。
    final saving = chat.save(config: chatA);
    letThrough(1);
    await forgetting;
    await written(2);
    letThrough(2);
    await saving;

    // 无论两个操作谁先执行，结果一致：配置保留、Key 已遗忘。
    final restored = (await repo.load())!;
    expect(restored.baseUrl, chatA.baseUrl);
    expect(restored.apiKey, isNull);
  });

  test('作用域切换与遗忘凭据交错，切换结果不丢也不沿用旧 Key', () async {
    await seedJson(chatJson('fake-chat-key-not-real'));
    final repo = repository();
    final secrets = _MemorySecretStore()
      ..values[chatA.credentialScope] = 'fake-legacy-key-not-real';
    final chat = chatService(repo, secrets);

    final switching = chat.save(
      config: chatB,
      apiKey: 'fake-new-key-not-real',
    );
    await written(1);
    final forgetting = chat.forgetApiKey();
    letThrough(1);
    await switching;
    await written(2);
    letThrough(2);
    await forgetting;

    // 切换完整生效：新作用域的配置在、随后遗忘把 Key 清空；两个作用
    // 域在凭据库里的遗留条目都被清理，不把旧作用域的 Key 带给新目标。
    final restored = (await repo.load())!;
    expect(restored.kind, ProviderKind.anthropic);
    expect(restored.baseUrl, chatB.baseUrl);
    expect(restored.apiKey, isNull);
    expect(await secrets.readApiKey(chatA.credentialScope), isNull);
    expect(await secrets.readApiKey(chatB.credentialScope), isNull);
  });

  test('语音转写保存与联网搜索保存交错，两段互不覆盖', () async {
    await seedJson({
      ...chatJson('fake-chat-key-not-real'),
      'stt': {
        'provider': 'openai_compatible',
        'baseUrl': 'https://stt.example.com/v1',
        'model': 'whisper-1',
        'apiKey': 'fake-stt-key-1-not-real',
      },
      'unknownKeeper': {'kept': true},
    });
    final repo = repository();
    final stt = sttService(repo);
    final search = searchService(repo);

    final savingStt = stt.save(
      baseUrl: 'https://stt.example.com/v1',
      model: 'whisper-2',
      apiKey: 'fake-stt-key-2-not-real',
    );
    await written(1);
    final savingSearch = search.save(apiKey: 'fake-search-key-not-real');
    letThrough(1);
    await savingStt;
    await written(2);
    letThrough(2);
    await savingSearch;

    final stored = await storedJson();
    // 语音段的新值不丢，搜索段照常落位，聊天 Key 与未知段保留。
    final sttSection = stored['stt']! as Map<String, Object?>;
    expect(sttSection['model'], 'whisper-2');
    expect(sttSection['apiKey'], 'fake-stt-key-2-not-real');
    expect(
      (stored['webSearch']! as Map<String, Object?>)['apiKey'],
      'fake-search-key-not-real',
    );
    expect(stored['apiKey'], 'fake-chat-key-not-real');
    expect(stored['unknownKeeper'], {'kept': true});
  });

  test('朗读开关保存与遗忘聊天 Key 交错，Key 不复活开关不丢', () async {
    await seedJson({
      ...chatJson('fake-chat-key-not-real'),
      'tts': {
        'provider': 'openai_compatible',
        'baseUrl': 'https://tts.example.com/v1',
        'model': 'tts-model',
        'autoSpeak': true,
        'apiKey': 'fake-tts-key-not-real',
      },
    });
    final repo = repository();
    final tts = ttsService(repo);
    final chat = chatService(repo);

    final toggling = tts.setAutoSpeak(false);
    await written(1);
    final forgetting = chat.forgetApiKey();
    letThrough(1);
    await toggling;
    await written(2);
    letThrough(2);
    await forgetting;

    final stored = await storedJson();
    expect((await repo.load())!.apiKey, isNull);
    expect((stored['tts']! as Map<String, Object?>)['autoSpeak'], isFalse);
    expect(
      (stored['tts']! as Map<String, Object?>)['apiKey'],
      'fake-tts-key-not-real',
    );
  });

  test('事务内写回失败只影响自身，队列释放后后续保存照常成功', () async {
    await seedJson(chatJson('fake-chat-key-not-real'));
    var failNext = true;
    final repo = JsonProviderConfigRepository(
      filePath: filePath,
      writer: FailingAtomicTextWriter(
        shouldFail: (_) {
          if (!failNext) {
            return false;
          }
          failNext = false;
          return true;
        },
      ),
    );
    final chat = chatService(repo);
    final proxy = proxyService(repo);
    final search = searchService(repo);

    // 第一次保存写回失败：异常按既有包装抛出。
    await expectLater(
      chat.save(config: chatA, apiKey: 'fake-chat-key-2-not-real'),
      throwsA(
        isA<ProviderConfigException>().having(
          (error) => error.message,
          'message',
          '本地模型配置无法保存。',
        ),
      ),
    );
    // 失败未落半截：文件保持原样。
    expect((await repo.load())!.apiKey, 'fake-chat-key-not-real');
    // 队列已释放：代理与搜索保存照常成功。
    final proxySaved = await proxy.save(
      enabled: true,
      host: 'proxy.example.com',
      port: 7890,
    );
    expect(proxySaved.enabled, isTrue);
    await search.save(apiKey: 'fake-search-key-not-real');

    final stored = await storedJson();
    expect(stored['proxy'], {
      'enabled': true,
      'host': 'proxy.example.com',
      'port': 7890,
    });
    expect(
      (stored['webSearch']! as Map<String, Object?>)['apiKey'],
      'fake-search-key-not-real',
    );
  });

  test('损坏文件经共享事务保存仍按既有语义整体重建', () async {
    await File(filePath).writeAsString('{ 这不是合法的 JSON');
    final repo = JsonProviderConfigRepository(filePath: filePath);

    await repo.runTransaction(
      () => repo.saveProxy(
        const ProxyConfig(enabled: true, host: 'proxy.example.com', port: 7890),
      ),
    );

    final stored = await storedJson();
    expect(stored.keys.toList(), ['proxy']);
  });
}

final class _MemorySecretStore implements SecretStore {
  final Map<String, String> values = {};

  @override
  Future<void> deleteApiKey(String scope) async => values.remove(scope);

  @override
  Future<String?> readApiKey(String scope) async => values[scope];
}

/// 配置保存与遗忘不触网：模型网关在本文件用例中只占装配位。
final class _UnusedModelGateway implements ModelGateway {
  @override
  Future<String> complete({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
    int? maxTokens,
  }) => Future.error(StateError('配置事务用例不调用模型'));
}
