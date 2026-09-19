import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_flutter/features/baseline/android_secret_store.dart';
import 'package:qiyu_flutter/features/baseline/host_bootstrap.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/settings_client.dart';

/// 安卓壳启动装配的验收（进程内真 127.0.0.1 服务器，与
/// `native_host_session_e2e_test` 同款先例）：证明「先起服务、再跑
/// UI、UI 显式指向它」的装配真实成立——
///
/// - 装配核心 [startEmbeddedHost] 起真 [LocalAppHost]（loopback 随机
///   端口）并产出会话接管绑定；
/// - 网关经绑定读设置、发聊天（本地规则引擎降级路径，无需真
///   Provider）；
/// - 危机输入在未连模型时由本地热线兜底接住（`safety` 降级标注，与
///   未配置 Provider 的 `no_llm_config` 降级可区分）；
/// - 凭据仓缺省接的是走平台通道的 [AndroidSecretStore]（票 05）：
///   凭据回退读取触发 get、文件接管触发 delete（末位测试，先于它的
///   用例保持未配置 Provider 的状态）。
///
/// 平台通道粘合（[bootstrapHost] 的目录解析与宪法资产读取）不在
/// dart 测试里 mock 平台通道，归真机冒烟。
void main() {
  late Directory root;
  late HostBinding binding;

  /// 模拟原生的密文条目表与调用记录（key = scope）。
  late Map<String, String> nativeEntries;
  late List<MethodCall> nativeCalls;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // flutter_test 的 binding 会把全局 HttpOverrides 换成「所有请求一律
    // 400」的测试桩（拦真网络，专为 testWidgets 的通道 mock 设计）；
    // 本文件先例是进程内真 127.0.0.1 服务器，这里还原为空让真 IO 恢复。
    // 凭据仓的通道模拟只走 binary messenger，与真 HTTP 互不干扰。
    HttpOverrides.global = null;
    nativeEntries = {};
    nativeCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(androidSecureStoreChannelName),
      (call) async {
        nativeCalls.add(call);
        final args = call.arguments! as Map<Object?, Object?>;
        final scope = args['scope']! as String;
        switch (call.method) {
          case 'get':
            return nativeEntries[scope];
          case 'set':
            nativeEntries[scope] = args['value']! as String;
            return null;
          case 'delete':
            nativeEntries.remove(scope);
            return null;
          default:
            throw StateError('unexpected method: ${call.method}');
        }
      },
    );
    root = await Directory.systemTemp.createTemp('qiyu-host-bootstrap-test-');
    final webRoot = Directory('${root.path}${Platform.pathSeparator}web')
      ..createSync(recursive: true);
    File(
      '${webRoot.path}${Platform.pathSeparator}index.html',
    ).writeAsStringSync('<!doctype html><title>栖语</title>');
    binding = await startEmbeddedHost(
      webRoot: webRoot.path,
      memoryDirectory: '${root.path}${Platform.pathSeparator}memories',
      personaConstitution: '测试人格宪法',
    );
  });

  tearDownAll(() async {
    await binding.shutdown();
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  test('装配绑定显式指向进程内 Host 的 loopback 随机端口', () {
    expect(binding.baseUri.scheme, 'http');
    expect(binding.baseUri.host, '127.0.0.1');
    expect(binding.baseUri.port, isNot(0));
  });

  test('读设置走装配绑定：经验选项读改写闭环', () async {
    final gateway = HttpSettingsGateway(
      client: binding.client,
      baseUri: binding.baseUri,
    );

    expect(
      (await gateway.savePreferences(developerMode: true)).developerMode,
      isTrue,
    );
    expect((await gateway.readPreferences()).developerMode, isTrue);
  });

  test('发聊天走装配绑定：本地规则引擎降级出回复', () async {
    final gateway = HttpLocalChatGateway(
      client: binding.client,
      baseUri: binding.baseUri,
    );

    final exchange = await gateway.send(
      requestId: 'bootstrap-normal-1',
      text: '今晚有点累',
    );

    expect(exchange.messages, isNotEmpty);
    expect(exchange.source, ReplySource.local);
    expect(exchange.fallbackReason, FallbackReason.noLlmConfig);
  });

  test('危机输入在未连模型时由本地热线兜底接住', () async {
    final gateway = HttpLocalChatGateway(
      client: binding.client,
      baseUri: binding.baseUri,
    );

    final exchange = await gateway.send(
      requestId: 'bootstrap-crisis-1',
      text: '我不想活了',
    );

    expect(exchange.messages, isNotEmpty);
    expect(exchange.source, ReplySource.local);
    // safety 降级（而非 no_llm_config）：分类只挑兜底话术，危机倾诉得到热线。
    expect(exchange.fallbackReason, FallbackReason.safety);
  });

  test('凭据仓装配走平台通道：读取回退触发 get，文件接管触发 delete',
      () async {
    final gateway = HttpProviderSettingsGateway(
      client: binding.client,
      baseUri: binding.baseUri,
    );
    final draft = ProviderSettingsDraft(
      provider: ProviderKind.openAiCompatible,
      baseUrl: 'https://doubao.example.com/v1',
      model: 'doubao-seed-1.6',
      temperature: 0.7,
      timeoutSeconds: 60,
    );

    // 保存不带 Key 的配置后读设置：文件无 Key，Host 走凭据仓回退读取
    // （当前作用域与旧版作用域各一次 get），证明安卓壳装配缺省接到的
    // 正是走平台通道的 AndroidSecretStore，而非内存易失仓。
    // 第一次 save 的返回快照与下面的显式 read 各触发一轮回退读取。
    await gateway.save(draft);
    expect((await gateway.read()).keySet, isFalse);
    expect(
      [for (final call in nativeCalls) call.method],
      everyElement('get'),
    );
    final fallbackScopes = {
      for (final call in nativeCalls) call.arguments!['scope']! as String,
    };
    expect(fallbackScopes, hasLength(2));

    // 保存带 Key 的配置：文件接管当前作用域，Host 立即清理凭据仓里的
    // 同作用域旧值（当前与旧版 scope 各一次 delete，通道侧幂等通过），
    // 此后读设置命中文件 Key，不再触发凭据回退。
    final saved = await gateway.save(
      ProviderSettingsDraft(
        provider: draft.provider,
        baseUrl: draft.baseUrl,
        model: draft.model,
        temperature: draft.temperature,
        timeoutSeconds: draft.timeoutSeconds,
        apiKey: 'sk-assembly-verification',
      ),
    );
    expect(saved.keySet, isTrue);
    expect(
      [for (final call in nativeCalls) call.method],
      ['get', 'get', 'get', 'get', 'delete', 'delete'],
    );
  });
}
