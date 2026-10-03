import 'package:qiyu_local_host/qiyu_local_host.dart';

/// 直构测试的记忆依赖族装配（票 10 / ADR 0022）：聊天服务构造期要求
/// 整族必填，测试按目录一次性备齐真实存储实例，接线与组合根
/// （local_app_host.dart）同构。迁移前「省略参数=功能关闭」的隔离
/// 语义由各成员的缺省形态承接：召回编排器不配模型客户端时轮内循环
/// 静默跳过，节奏模块缺省构造在未接日终归档时各钩子均为空转，热层
/// 读取器读不到材料时对应块保持原值。
///
/// [episodePipeline] 供需要与节奏/日终归档共享同一管线实例的夹具
/// 复用；[memoryCadence] 供需要挂接真实日终归档链的夹具传入；
/// [recallModelClient] 与 [aliasClient] 供 Omni 实时通话夹具（T03）
/// 接入选中 Provider 的查找选择小调用与控制别名扩展。
ChatMemoryModule buildChatMemoryModule({
  required String memoryDirectory,
  DateTime Function()? clock,
  AtomicTextWriter? atomicWriter,
  EpisodeMemoryPipeline? episodePipeline,
  MemoryCadence? memoryCadence,
  ProviderChatClient? recallModelClient,
  ProviderChatClient? aliasClient,
}) {
  final pipeline =
      episodePipeline ??
      EpisodeMemoryPipeline(
        memoryDirectory: memoryDirectory,
        clock: clock,
        atomicWriter: atomicWriter,
      );
  final controls = MemoryControlsStore(
    memoryDirectory: memoryDirectory,
    commits: pipeline.commits,
    atomicWriter: atomicWriter,
  );
  final loops = OpenLoopStore(
    memoryDirectory: memoryDirectory,
    memoryControls: controls,
    atomicWriter: atomicWriter,
  );
  final tree = PersonaTreeStore(
    memoryDirectory: memoryDirectory,
    episodePipeline: pipeline,
    openLoopStore: loops,
    atomicWriter: atomicWriter,
  );
  final monthly = MonthlySummaryStore(
    memoryDirectory: memoryDirectory,
    episodePipeline: pipeline,
    openLoopStore: loops,
    atomicWriter: atomicWriter,
  );
  final actions = MemoryActionService(
    memoryDirectory: memoryDirectory,
    episodePipeline: pipeline,
    personaTree: tree,
    memoryControls: controls,
    openLoopStore: loops,
    monthlySummary: monthly,
    relationshipLifecycle: RelationshipLifecycle(
      memoryDirectory: memoryDirectory,
      atomicWriter: pipeline.commits.wrap(atomicWriter),
      clock: clock,
    ),
    atomicWriter: atomicWriter,
    aliasClient: aliasClient,
  );
  return ChatMemoryModule(
    episodePipeline: pipeline,
    openLoopStore: loops,
    memoryControls: controls,
    memoryActions: actions,
    memoryCadence: memoryCadence ?? MemoryCadence(clock: clock),
    memoryRecall: RecallOrchestrator(
      memoryDirectory: memoryDirectory,
      episodePipeline: pipeline,
      openLoopStore: loops,
      personaTree: tree,
      modelClient: recallModelClient,
    ),
    personaTree: tree,
    statePackReader: StatePackReader(
      memoryDirectory: memoryDirectory,
      openLoopStore: loops,
      clock: clock,
    ),
  );
}
