import 'dart:io';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

import 'support/chat_memory_test_module.dart';

/// 记忆依赖族构造期校验（票 10 / ADR 0022）：控制存储与开环存储的
/// 同实例不变量从注释约定升级为构造期校验——错配的装配构造即抛出，
/// 两条写入链互相覆盖的风险在启动前暴露。
void main() {
  Directory tempDirectory() => Directory.systemTemp.createTempSync(
    'qiyu-memory-module-test-',
  );

  group('ChatMemoryModule 构造期校验', () {
    test('控制存储与开环存储同实例时构造通过', () {
      final directory = tempDirectory();
      addTearDown(() => directory.delete(recursive: true));
      final module = buildChatMemoryModule(memoryDirectory: directory.path);
      expect(
        identical(module.memoryControls, module.openLoopStore.memoryControls),
        isTrue,
      );
    });

    test('控制存储与开环存储各持一个实例时构造抛出', () {
      final directory = tempDirectory();
      addTearDown(() => directory.delete(recursive: true));
      final pipeline = EpisodeMemoryPipeline(memoryDirectory: directory.path);
      final standaloneControls = MemoryControlsStore(
        memoryDirectory: directory.path,
        commits: pipeline.commits,
      );
      final loops = OpenLoopStore(memoryDirectory: directory.path);
      final tree = PersonaTreeStore(
        memoryDirectory: directory.path,
        episodePipeline: pipeline,
        openLoopStore: loops,
      );
      final actions = MemoryActionService(
        memoryDirectory: directory.path,
        episodePipeline: pipeline,
        personaTree: tree,
        // 动作执行端接入开环存储持有的控制存储（正确一侧）。
        memoryControls: loops.memoryControls,
        openLoopStore: loops,
        monthlySummary: MonthlySummaryStore(
          memoryDirectory: directory.path,
          episodePipeline: pipeline,
          openLoopStore: loops,
        ),
        relationshipLifecycle: RelationshipLifecycle(
          memoryDirectory: directory.path,
        ),
      );
      expect(
        () => ChatMemoryModule(
          episodePipeline: pipeline,
          openLoopStore: loops,
          // 错配注入：独立构造的控制存储与开环存储自建的另一个实例并存，
          // 聊天即时控制与开环热层会各写各的控制文件。
          memoryControls: standaloneControls,
          memoryActions: actions,
          memoryCadence: MemoryCadence(),
          memoryRecall: RecallOrchestrator(
            memoryDirectory: directory.path,
            episodePipeline: pipeline,
          ),
          personaTree: tree,
          statePackReader: StatePackReader(
            memoryDirectory: directory.path,
            openLoopStore: loops,
          ),
        ),
        throwsArgumentError,
      );
    });
  });
}
