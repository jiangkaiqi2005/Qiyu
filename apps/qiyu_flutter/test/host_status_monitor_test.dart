import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/settings/embedding_settings_client.dart';
import 'package:qiyu_flutter/features/shell/host_status_monitor.dart';

import 'support/shared_fakes.dart';

/// HostStatusMonitor 的记忆召回分支（票 03/04）：随既有轮询节拍读取
/// 状态快照，只对需要打扰用户的三态（准备中/需重建/暂不可用）占位；
/// 未启用、已就绪与更新中（增量同步不打扰正常聊天）安静；读取失败
/// 保持上一份快照；状态未变化不重复通知。
void main() {
  EmbeddingSettings settingsFor(
    String state, {
    int pendingCount = 0,
  }) => EmbeddingSettings(
    configured: true,
    keySet: true,
    enabled: state != 'disabled',
    baseUrl: 'https://embedding.example.com/v1',
    model: 'text-embedding-test',
    rag: MemoryRecallStatus(
      state: state,
      progressDone: 1,
      progressTotal: 3,
      pendingCount: pendingCount,
      reason: state == 'unavailable' ? '记忆召回服务连接超时。' : null,
    ),
  );

  test('准备中/需重建/暂不可用照实暴露，未启用与已就绪安静', () async {
    final gateway = _FixedRecallGateway(settingsFor('preparing'));
    final monitor = _monitor(gateway);
    addTearDown(monitor.dispose);
    await monitor.checkHostNow();
    expect(monitor.memoryRecallStatus?.state, 'preparing');
    expect(monitor.memoryRecallStatus?.progressDone, 1);
    expect(monitor.memoryRecallStatus?.progressTotal, 3);

    gateway.settings = settingsFor('ready');
    await monitor.checkHostNow();
    expect(monitor.memoryRecallStatus, isNull, reason: '已就绪安静');

    gateway.settings = settingsFor('disabled');
    await monitor.checkHostNow();
    expect(monitor.memoryRecallStatus, isNull, reason: '未启用安静');

    gateway.settings = settingsFor('rebuildNeeded');
    await monitor.checkHostNow();
    expect(monitor.memoryRecallStatus?.state, 'rebuildNeeded');

    gateway.settings = settingsFor('unavailable');
    await monitor.checkHostNow();
    expect(monitor.memoryRecallStatus?.state, 'unavailable');
    expect(monitor.memoryRecallStatus?.reason, contains('连接超时'));
  });

  test('更新中不占聊天输入旁的提示位（票 04）', () async {
    final gateway = _FixedRecallGateway(
      settingsFor('updating', pendingCount: 2),
    );
    final monitor = _monitor(gateway);
    addTearDown(monitor.dispose);
    await monitor.checkHostNow();
    expect(
      monitor.memoryRecallStatus,
      isNull,
      reason: '增量同步是非阻塞后台活动，不在聊天旁打扰',
    );
    // 快照字段完整穿透（设置页完整状态使用同一快照）。
    expect(gateway.settings?.rag?.pendingCount, 2);
  });

  test('状态取不到（Host 侧失败）时保持原样，不打扰聊天主链路', () async {
    final gateway = _FixedRecallGateway(settingsFor('unavailable'));
    final monitor = _monitor(gateway);
    addTearDown(monitor.dispose);
    await monitor.checkHostNow();
    expect(monitor.memoryRecallStatus?.state, 'unavailable');

    gateway.throwOnRead = true;
    await monitor.checkHostNow();
    expect(monitor.memoryRecallStatus?.state, 'unavailable');
  });

  test('状态未变化不重复通知；变化才通知', () async {
    final gateway = _FixedRecallGateway(settingsFor('preparing'));
    final monitor = _monitor(gateway);
    addTearDown(monitor.dispose);
    var notifications = 0;
    monitor.addListener(() => notifications += 1);

    await monitor.checkHostNow();
    final afterFirst = notifications;
    expect(afterFirst, greaterThanOrEqualTo(1));

    // 同一状态快照（值相等）：不重复通知。
    await monitor.checkHostNow();
    expect(notifications, afterFirst);

    // 状态变化：通知。
    gateway.settings = settingsFor('ready');
    await monitor.checkHostNow();
    expect(notifications, greaterThan(afterFirst));
  });
}

HostStatusMonitor _monitor(_FixedRecallGateway gateway) => HostStatusMonitor(
  hostConnectionProbe: FakeHostConnectionProbe(const [true]),
  memoryRecallStatusGateway: gateway,
  autoStart: false,
);

final class _FixedRecallGateway implements MemoryRecallStatusGateway {
  _FixedRecallGateway(this.settings);

  EmbeddingSettings? settings;
  bool throwOnRead = false;

  @override
  Future<EmbeddingSettings?> read() async {
    if (throwOnRead) {
      throw Exception('host unreachable');
    }
    return settings;
  }
}
