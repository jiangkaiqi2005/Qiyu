import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'chat_memory_module.dart';
import 'markdown_memory_repository.dart';
import 'memory_actions.dart';
import 'memory_alias.dart';
import 'memory_ban.dart';
import 'memory_text_primitives.dart';
import 'persona_tree.dart';
import 'provider_settings_service.dart';

/// 可见回复落盘之后的增量记忆执行端（T03 从 LocalChatService 抽出）：
/// 轮内整理（episode 管线 + 画像树建叶）、用户记忆控制（禁提/冻结/
/// 解除/删除，回复后异步立即生效）与对话自述称呼的在线写路径。聊天
/// 主链与 Omni 实时通话共用同一实例逻辑——动作语义、提交边界（维护
/// 准入之外的别名扩展 + 执行器内短写锁）与「只记诊断不影响交付」的
/// 失败纪律完全一致，两条链路不各养一份实现。
final class HiddenActionExecutor {
  HiddenActionExecutor({
    required this.memory,
    this.aliasClient,
    required this.diagnosticsSink,
  });

  final ChatMemoryModule memory;

  /// 控制时关联扩展的 Provider 客户端（裁定票 03）：禁提与冻结两个
  /// 分支做有界别名调用。未配置或调用失败都静默退回无别名，控制本身
  /// 照常生效。
  final ProviderChatClient? aliasClient;

  /// 诊断出口：只记来源与结果级细节，绝不记用户文本。
  final void Function(String message) diagnosticsSink;

  /// 对话自述称呼（用户说「以后叫我老王」）当轮生效：与用户明确
  /// 纠正同一精神，用户当前明确说的话最高；本地降级轮同样生效。
  /// 必须赶在轮内召回之前写入——召回的组织调用按 persona.md 的
  /// 称呼装配。
  Future<void> applyAppellation(String userText, String requestId) async {
    final candidate = extractAppellationSelfReport(userText);
    if (candidate == null) {
      return;
    }
    try {
      final written = await memory.personaTree.episodePipeline.commits
          .existingOperation(() => memory.personaTree.setAppellation(candidate));
      if (written == null) {
        diagnosticsSink(
          'appellation self-report rejected reason=format '
          'request=$requestId',
        );
      }
    } on Object catch (error) {
      diagnosticsSink(
        'appellation self-report deferred [$error] request=$requestId',
      );
    }
  }

  /// 提交本轮隐藏动作（只在完整且最终被接受的模型回复后调用）：
  /// 候选被行为核心拒绝（回退本地回复）时整体丢弃——不改控制记录、
  /// 不写派生记忆、不触发轮内召回；协议失败留下的半句同样没有可提交
  /// 的动作（文本如实落盘，动作不落地）；失败与取消的轮次根本没有
  /// 可提交的动作。
  Future<void> applyActions(
    RawSession completedSession,
    String requestId,
    List<HiddenAction> hiddenActions,
  ) async {
    // 不要记（当轮控制，不产生持久记录）：命中目标的记忆信号、
    // 未完事项候选与关系证据一律不落 episode——内容不进提升、索引
    // 或 PersonaTree；控制动作自身保留为审计条目。
    final forgetTargets = hiddenActions
        .whereType<MemoryForgetAction>()
        .map((action) => normalizeMemoryText(action.title))
        .where((summary) => summary.isNotEmpty)
        .toSet();
    var effectiveActions = hiddenActions;
    if (forgetTargets.isNotEmpty) {
      effectiveActions = hiddenActions.where((action) {
        final summary = switch (action) {
          MemorySignalAction() => action.summary,
          OpenLoopCandidateAction() => action.title,
          RelationshipSignalAction() => action.summary,
          OpenLoopStatusAction() ||
          MemoryControlAction() ||
          MemoryRecallAction() ||
          NoAction() => null,
        };
        if (summary == null) {
          return true;
        }
        return !bannedMemoryText(summary, forgetTargets);
      }).toList();
    }

    final pipeline = memory.episodePipeline;
    try {
      final result = await pipeline.processReply(
        session: completedSession,
        requestId: requestId,
        hiddenActions: effectiveActions,
      );
      if (result.skippedCorruptDay) {
        diagnosticsSink(
          'episode day unreadable, waiting for recovery request=$requestId',
        );
      }
      // 随手记只建叶指针（ticket 14）：中间理解归日终。建叶失败
      // 只记诊断，日终还会按当天 episode 补齐。
      if (result.addedEntries.isNotEmpty) {
        await memory.personaTree.createLeaves(result.addedEntries);
        // 用户明确纠正是唯一在线撤根例外（ticket 17）：当轮身份自述
        // 与根下理解冲突时立即撤根并重投影 persona.md，不等日终。
        await memory.personaTree.revokeCorrectedIdentityRoots(
          result.addedEntries,
        );
      }
    } on Object catch (error) {
      diagnosticsSink('episode update deferred [$error] request=$requestId');
    }
    // 记忆控制与 Open-loop 状态变化：回复后异步立即生效，不等日终。
    for (final action in hiddenActions) {
      try {
        switch (action) {
          case OpenLoopStatusAction():
            await memory.openLoopStore.applyStatusChange(
              title: action.title,
              status: action.status.wireName,
              result: action.result,
            );
          case MemoryBanAction():
            final execution = memory.memoryActions.banExecution;
            // 别名扩展在维护准入之外：模型调用不占 operation zone
            // （提交边界纪律），未配置或失败静默退回无别名，禁提本身
            // 照常生效。
            final aliases = await expandMemoryAliases(
              aliasClient,
              action.title,
            );
            // 此处已经占有聊天槽，维护正在排空聊天时必须继续完成，
            // 不能再等待新 UI 操作的准入。执行器只分步取得短写锁。
            final result = await execution.controls.commits.existingOperation(
              () => execution.execute(
                action.title,
                origin: 'chat',
                aliases: aliases,
              ),
            );
            if (!result.controlWritten) {
              diagnosticsSink(
                'memory ban deferred [controls not writable] '
                'request=$requestId',
              );
            } else {
              for (final step in result.deferred) {
                final reason = switch (step) {
                  MemoryBanCleanup.openLoops => 'open-loops',
                  MemoryBanCleanup.persona => 'persona',
                };
                diagnosticsSink(
                  'memory ban deferred [$reason] request=$requestId',
                );
              }
            }
          case MemoryFreezeAction():
            // 关联扩展（裁定票 03）：未配置模型或调用失败都静默退回
            // 无别名，冻结本身照常生效。
            final aliases = await expandMemoryAliases(aliasClient, action.title);
            final frozen = await memory.memoryControls.freeze(
              action.title,
              aliases: aliases,
            );
            if (!frozen) {
              diagnosticsSink(
                'memory freeze deferred [controls not writable] '
                'request=$requestId',
              );
            }
          case MemoryUnfreezeAction():
            // 返回 null 即控制记录写不进（可恢复失败）：控制保持现状
            // 等待重试。
            final removed = await memory.memoryControls.unfreeze(action.title);
            if (removed == null) {
              diagnosticsSink(
                'memory unfreeze deferred [controls not writable] '
                'request=$requestId',
              );
            }
          case MemoryUnbanAction():
            // 口语解除禁提（裁定票 03）：与 memory_unfreeze 对称，写失败
            // 只记诊断，控制记录保持现状等待重试。
            final removed = await memory.memoryControls.unban(action.title);
            if (removed == null) {
              diagnosticsSink(
                'memory unban deferred [controls not writable] '
                'request=$requestId',
              );
            }
          case MemoryDeleteAction():
            await _applyDelete(action.title, requestId);
          case MemorySignalAction() ||
              OpenLoopCandidateAction() ||
              RelationshipSignalAction() ||
              MemoryForgetAction() ||
              MemoryRecallAction() ||
              NoAction():
            break;
        }
        // memory_forget 是当轮控制：内容过滤已在上面执行，
        // 审计条目随 episode 落盘，没有额外的持久动作。
      } on Object catch (error) {
        diagnosticsSink('memory control deferred [$error] request=$requestId');
      }
    }
  }

  /// 删除即时生效（ticket 18 / T24 定稿，ticket 20 起与记忆中心共用
  /// [MemoryActionService] 同一管线）：先定位目标，无任何可定位目标
  /// 时不写控制记录也不清除——绝不把宽泛范围变成永久封禁；定位到
  /// 目标后先写 deleted 抽象防复活范围，再清除全部派生内容
  /// （PersonaTree、episodes 与索引、长期印象、月摘要、关系证据、
  /// 近日状态、未闭环事项）。sessions 保留；重复执行安全。
  Future<void> _applyDelete(String summary, String requestId) async {
    if (normalizeMemoryText(summary).isEmpty) {
      return;
    }
    final result = await memory.memoryActions.deleteByScope(
      summary,
      origin: 'chat',
      requestId: requestId,
    );
    if (result.status != MemoryActionStatus.success) {
      diagnosticsSink(
        'memory delete deferred [${result.status.wireName}] '
        'request=$requestId',
      );
    }
  }
}
