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
  });

  final bool controlWritten;
  final List<MemoryBanCleanup> deferred;
}

/// 已解析目标的禁提执行。整项受维护准入保护，各存储只在实际读改写
/// 时取得短提交锁；控制成功便使旧 Dream 候选失效。
final class MemoryBanExecution {
  MemoryBanExecution({required this.openLoopStore, this.personaTree});

  final OpenLoopStore openLoopStore;
  final PersonaTreeStore? personaTree;

  MemoryControlsStore get controls => openLoopStore.memoryControls;

  Future<MemoryBanResult> execute(String scope, {required String origin}) =>
      controls.commits.operation(() async {
        if (!await controls.ban(scope, origin: origin)) {
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
        );
      });
}
