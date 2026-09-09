import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_flutter/features/baseline/host_bootstrap.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/settings/settings_client.dart';

/// 安卓壳启动装配的验收（进程内真 127.0.0.1 服务器，与
/// `native_host_session_e2e_test` 同款先例）：证明「先起服务、再跑
/// UI、UI 显式指向它」的装配真实成立——
///
/// - 装配核心 [startEmbeddedHost] 起真 [LocalAppHost]（loopback 随机
///   端口）并产出会话接管绑定；
/// - 网关经绑定读设置、发聊天（本地规则引擎降级路径，无需真
///   Provider）；
/// - 危机输入在装配链路上仍被本地分类先拦（`safety` 降级标注，与
///   未配置 Provider 的 `no_llm_config` 降级可区分）。
///
/// 平台通道粘合（[bootstrapHost] 的目录解析与宪法资产读取）不在
/// dart 测试里 mock 平台通道，归真机冒烟。
void main() {
  late Directory root;
  late HostBinding binding;

  setUpAll(() async {
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

  test('危机输入在装配链路上被本地分类先拦，绝不调 Provider', () async {
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
    // safety 降级（而非 no_llm_config）证明本地安全分类先于一切运行。
    expect(exchange.fallbackReason, FallbackReason.safety);
  });
}
