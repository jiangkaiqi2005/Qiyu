import 'memory_controls.dart';
import 'memory_text_primitives.dart';
import 'open_loop_store.dart';
import 'persona_tree.dart';

enum MemoryBanCleanup { openLoops, persona }

/// 控制是否落盘与独立清理的失败事实；入口各自决定如何呈现。
final class MemoryBanResult {
  const MemoryBanResult({
    required this.controlWritten,
    this.deferred = const [],
    this.aliasCount = 0,
  });

  final bool controlWritten;
  final List<MemoryBanCleanup> deferred;

  /// 随控制一起写入的相近表述条数（裁定票 03）：聊天路径不展示，
  /// 记忆中心经 MemoryActionResult 透出给界面。
  final int aliasCount;
}

/// 已解析目标的禁提执行。整项受维护准入保护，各存储只在实际读改写
/// 时取得短提交锁；控制成功便使旧 Dream 候选失效。
///
/// 别名（控制时模型关联扩展，裁定票 03）由调用方在进入维护准入之前
/// 备好经 [aliases] 传入：模型调用必须留在锁外（提交边界纪律），
/// 执行器自身只做本地写入。未配置模型或调用失败时传空列表即可，
/// 控制本身照常成功。
final class MemoryBanExecution {
  MemoryBanExecution({required this.openLoopStore, this.personaTree});

  final OpenLoopStore openLoopStore;
  final PersonaTreeStore? personaTree;

  MemoryControlsStore get controls => openLoopStore.memoryControls;

  Future<MemoryBanResult> execute(
    String scope, {
    required String origin,
    List<String> aliases = const [],
  }) => controls.commits.operation(() async {
    if (!await controls.ban(scope, origin: origin, aliases: aliases)) {
      return const MemoryBanResult(controlWritten: false);
    }
    final deferred = <MemoryBanCleanup>[];
    try {
      await openLoopStore.removeLoopsMatching({normalizeMemoryText(scope)});
    } on Object {
      deferred.add(MemoryBanCleanup.openLoops);
    }
    try {
      await personaTree?.applyBan(scope);
    } on Object {
      deferred.add(MemoryBanCleanup.persona);
    }
    return MemoryBanResult(
      controlWritten: true,
      deferred: List.unmodifiable(deferred),
      aliasCount: aliases.length,
    );
  });
}
