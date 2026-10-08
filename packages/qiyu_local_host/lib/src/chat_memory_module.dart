import 'episode_memory.dart';
import 'episode_rag_service.dart';
import 'memory_actions.dart';
import 'memory_cadence.dart';
import 'memory_controls.dart';
import 'memory_recall.dart';
import 'open_loop_store.dart';
import 'persona_tree.dart';
import 'state_pack_reader.dart';

/// 聊天服务的记忆依赖族（票 10 / ADR 0022）：episode 管线、开环存储、
/// 控制存储、动作执行端、交付节奏、召回编排、画像树与热层读取器收成
/// 一个必填 module。这些依赖各自撑起聊天里的一条功能路径（轮内整理、
/// 开环即时生效、禁提/冻结/删除、维护准入、交付后节奏、轮内召回、
/// 称呼自述写盘、热层装配），缺失任何一个成员对应功能就会静默消失
/// ——收拢后忘注入在构造期报错，成员实例由组合根一次性备齐。
///
/// 同实例不变量在构造期校验：[memoryControls] 必须与 [openLoopStore]
/// 内部持有的控制存储是同一实例（[OpenLoopStore.memoryControls]）。
/// 开环热层与聊天即时控制两条写入链共用一个控制存储，各持一个实例
/// 会互相覆盖——错配的装配现在构造即抛出，与注释约定同律。
final class ChatMemoryModule {
  ChatMemoryModule({
    required this.episodePipeline,
    required this.openLoopStore,
    required this.memoryControls,
    required this.memoryActions,
    required this.memoryCadence,
    required this.memoryRecall,
    required this.personaTree,
    required this.statePackReader,
    this.embeddingRecall,
  }) {
    if (!identical(memoryControls, openLoopStore.memoryControls)) {
      throw ArgumentError(
        'memoryControls 必须与 openLoopStore 持有的控制存储同实例：'
        '两条写入链各持一个实例会互相覆盖'
        '（用 OpenLoopStore 的 memoryControls 参数接入同一实例）',
      );
    }
  }

  /// episode 日文件管线与提交边界：轮内记忆整理、维护准入
  /// （runExclusively 经它的 commits 排队）与召回索引重建共用。
  final EpisodeMemoryPipeline episodePipeline;

  /// 开环（未完事项）存储：模型提议的状态变化在回复后即时落盘。
  final OpenLoopStore openLoopStore;

  /// 用户记忆控制记录（ticket 18）：冻结/禁提/删除的落盘与读取。
  /// 必须与 [openLoopStore] 内部持有的是同一实例（构造期校验）。
  final MemoryControlsStore memoryControls;

  /// 记忆动作执行端（ticket 20）：聊天禁提走它的禁提执行器、删除走
  /// 它的删除管线，与记忆中心 UI 共用同一实例，控制范围与清理结果
  /// 保持一致。
  final MemoryActionService memoryActions;

  /// 记忆节奏（ticket 22 / ADR 0002）：交付后时间节奏链独立模块。
  /// 聊天服务只在每轮交付完成（轮内召回循环之后）调
  /// [MemoryCadence.onDeliveryComplete] 一个钩子，危险操作独占前经
  /// [MemoryCadence.finalizePending] 等它的后台任务链排空；日终归档、
  /// 月压缩、Dream、启动补扫与空闲补办全部在模块内部串行。
  final MemoryCadence memoryCadence;

  /// 召回模型查找轮内循环。查找由模型隐藏动作触发：命中快时当轮补
  /// bubble 2，没赶上时压缩结果注入下一轮模型上下文；模型客户端未
  /// 配置时整个轮内循环静默跳过（召回是增强，回复链路照常）。
  final RecallOrchestrator memoryRecall;

  /// PersonaTree 叶与中间理解（ticket 14）。必须与日终归档使用
  /// 同一实例：树文件的串行锁在实例内部，两个实例会互相覆盖。
  final PersonaTreeStore personaTree;

  /// 热层三块（【近况】、【长期印象】、【用户画像】）的串行读取与
  /// 既有记忆控制过滤，模型调用前由 [StatePackReader.readHotLayerBlocks]
  /// 完成装配。
  final StatePackReader statePackReader;

  /// Episode RAG 服务（票 03）：用户显式启用后的语义向量定位。与
  /// [memoryRecall] 共享组合根创建的同一实例；null 时召回全部走旧
  /// 目录路径（未启用语义与现状一致）。维护独占（runExclusively）
  /// 经它排空在途构建并在导入/回滚/清除后失效缓存。
  final EpisodeRagService? embeddingRecall;
}
