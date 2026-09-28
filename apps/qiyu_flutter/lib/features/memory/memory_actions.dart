import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../theme/qiyu_icons.dart';
import '../../theme/qiyu_theme.dart';
import '../../theme/qiyu_tokens.dart';
import '../shell/qiyu_fading_notice.dart';
import '../shell/qiyu_ui_locale.dart';
import '../shell/qiyu_widgets.dart';
import 'memory_client.dart';
import 'memory_strings.dart';
import 'memory_view_model.dart';

/// 临时揭示的自动重新遮罩时间：只作本次展示，离开页面立即失效。
const Duration revealTimeout = Duration(seconds: 20);

/// 一条记忆上可执行的动作（ticket 20，架构深化 ticket 08 收拢为共享
/// 动作模块）。值序即常驻按钮的定序；[label] 一份文案两个用途：按钮
/// 的 tooltip，以及带进语义树的无障碍标签（实测 IconButton 的 tooltip
/// 只落到语义节点的 tooltip 属性上，label 是空的，触屏与读屏都读不到
/// 动作名，所以标签由 [MemoryActionButtons] 显式给出）。图形取
/// design-system §4 定案的五枚（铅笔 / 雪花 / 禁止圈 / 垃圾桶 / 眼睛）；
/// 恢复使用与解除禁提沿用同一图形，两态靠状态芯片与动作名区分。
enum MemoryAction {
  edit('修正', 'Correct', QiyuIcons.edit),
  reveal('临时查看', 'View temporarily', QiyuIcons.visibility),
  freeze('暂停使用', 'Pause use', QiyuIcons.ac_unit),
  unfreeze('恢复使用', 'Resume use', QiyuIcons.ac_unit),
  ban('不再提起', 'Do not bring up', QiyuIcons.block),
  unban('解除禁提', 'Allow again', QiyuIcons.block),
  delete('删除', 'Delete', QiyuIcons.delete);

  const MemoryAction(this.label, this.enLabel, this.icon);

  final String label;
  final String enLabel;
  final IconData icon;

  String labelFor(BuildContext context) => qiyuIsEn(context) ? enLabel : label;
}

/// 条目动作状态快照：列表卡片与详情页各自从自己的 DTO 提取，喂给
/// 同一份 [MemoryActionPlan]。
final class MemoryItemActionState {
  const MemoryItemActionState({
    required this.control,
    required this.masked,
    this.editable = false,
  });

  final MemoryControlStatus? control;
  final bool masked;

  /// 条目类别是否提供修正（episode 条目可；画像与状态包行不是修正
  /// 对象，只能通过对话纠正）。
  final bool editable;
}

/// 动作的确认要求：哪些动作先过明确确认再落盘（T25 定稿：禁提要
/// 确认、删除要确认，冻结直接生效）。
enum MemoryActionConfirmation { none, ban, delete }

/// 定型动作计划：**唯一一份**「可用性 × 确认」矩阵。列表按钮与详情页
/// 动作都从这里取在场与可点，执行器也从这里取确认要求来分派确认
/// 流程，不各自维护一套条件——一处可点另一处灰掉、确认要求两份口径
/// 的矛盾都从这里杜绝。
final class MemoryActionPlan {
  const MemoryActionPlan({required this.state, this.busy = false});

  final MemoryItemActionState state;

  /// 有写入动作在执行：在场按钮一律灰掉防重复触发（结果落盘确认前
  /// 不呈现「已完成」）；可用性本身不变。
  final bool busy;

  /// 该动作在这条状态下是否在场（是否提供这一颗）。
  bool offered(MemoryAction action) => switch (action) {
    MemoryAction.edit => state.editable && !state.masked,
    // 不揭示原文就不能改；反过来，未遮罩没有要揭示的东西。
    MemoryAction.reveal => state.masked,
    MemoryAction.freeze => state.control == null,
    MemoryAction.unfreeze => state.control == MemoryControlStatus.frozen,
    MemoryAction.ban => state.control == null,
    MemoryAction.unban => state.control == MemoryControlStatus.banned,
    MemoryAction.delete => true,
  };

  /// 该动作此刻是否可点：在场且没有写入动作挂起。
  bool enabled(MemoryAction action) => offered(action) && !busy;

  /// 该动作的确认要求：动作的定型属性、不随条目状态变化（T25 定稿
  /// 对所有条目一视同仁），任意状态快照上查询等价——执行器据此分派
  /// 确认流程，动作是否需要确认只在这里回答一次。
  MemoryActionConfirmation confirmationOf(MemoryAction action) =>
      switch (action) {
        MemoryAction.ban => MemoryActionConfirmation.ban,
        MemoryAction.delete => MemoryActionConfirmation.delete,
        _ => MemoryActionConfirmation.none,
      };

  /// 按定序给出的全部在场动作（列表按钮的渲染序）。
  List<MemoryAction> get offeredActions => [
    for (final action in MemoryAction.values)
      if (offered(action)) action,
  ];
}

/// 记忆动作执行器：唯一一份「确认 → 执行 → 反馈」流程，列表按钮与
/// 详情页动作都从它走。确认要求只认 [MemoryActionPlan.confirmationOf]
/// 这一份矩阵：计划要求确认的动作先过各自的确认对话框，取消不产生
/// 任何动作；计划放行的动作才进入直接执行分派。新增需确认动作时只
/// 改计划矩阵并提供对应流程，这里不再各写一份「动作 → 是否确认」。
///
/// 上下文存活防护统一收在这里：发起动作的界面（列表条目或详情页）在
/// 任一 await 之后已销毁时，续段立即收手——不再弹对话框、不再落揭示
/// 状态、也不再挂结果横幅。数据写入由 ViewModel 负责，不依赖界面
/// 存活，所以收手只影响呈现，不影响落盘与总览刷新。
Future<void> runMemoryAction(
  BuildContext context, {
  required MemoryAction action,
  required String itemId,
  String? currentText,
  String revealField = 'content',

  /// 揭示成功的落点：详情页按字段把原文写进自己的临时揭示状态；
  /// 缺省（列表遮罩条目）在一次性对话框里展示，关闭即重新遮罩。
  void Function(String text)? onRevealed,
}) async {
  final viewModel = context.read<MemoryCenterViewModel>();
  // 确认要求不随条目状态变化（见 [MemoryActionPlan.confirmationOf]），
  // 用任意状态快照查询即可；这里没有条目状态，也不为查确认编造。
  const plan = MemoryActionPlan(
    state: MemoryItemActionState(control: null, masked: false),
  );
  switch (action) {
    case MemoryAction.edit:
      await _runEditFlow(
        context,
        viewModel: viewModel,
        itemId: itemId,
        current: currentText ?? '',
      );
    case MemoryAction.reveal:
      await _runRevealFlow(
        context,
        viewModel: viewModel,
        itemId: itemId,
        field: revealField,
        onRevealed: onRevealed,
      );
    case MemoryAction.freeze:
      await _runDirect(context, run: viewModel.freeze, itemId: itemId);
    case MemoryAction.unfreeze:
      await _runDirect(context, run: viewModel.unfreeze, itemId: itemId);
    case MemoryAction.unban:
      await _runDirect(context, run: viewModel.unban, itemId: itemId);
    case MemoryAction.ban:
    case MemoryAction.delete:
      // 确认流程按计划矩阵分派，ban/delete 自己不再各写一份「要不要
      // 确认」。计划把确认要求改成 none 而这里没跟上时，宁可在测试期
      // 断言失败，也不静默执行或跳过一个破坏性动作。
      switch (plan.confirmationOf(action)) {
        case MemoryActionConfirmation.ban:
          await _runBanFlow(context, viewModel: viewModel, itemId: itemId);
        case MemoryActionConfirmation.delete:
          await _runDeleteFlow(context, viewModel: viewModel, itemId: itemId);
        case MemoryActionConfirmation.none:
          assert(false, '$action 不再要求确认，需要补直接执行流程');
      }
  }
}

/// 修正流程：对话框预填现有文本，保存按用户声明落盘。
Future<void> _runEditFlow(
  BuildContext context, {
  required MemoryCenterViewModel viewModel,
  required String itemId,
  required String current,
}) async {
  final updated = await showDialog<String>(
    context: context,
    builder: (dialogContext) => _EditDialog(initial: current),
  );
  if (updated == null || updated.trim().isEmpty) {
    return;
  }
  final result = await viewModel.edit(itemId, updated.trim());
  if (!context.mounted) {
    return; // 发起处界面已销毁：不再挂结果横幅。
  }
  showMemoryActionResult(context, result);
}

/// 临时揭示流程：只取一次原文；成功后交给 [onRevealed]（详情页）或
/// 一次性对话框（列表），原文绝不落任何持久状态。
Future<void> _runRevealFlow(
  BuildContext context, {
  required MemoryCenterViewModel viewModel,
  required String itemId,
  required String field,
  required void Function(String text)? onRevealed,
}) async {
  final result = await viewModel.reveal(itemId, field: field);
  if (!context.mounted) {
    return; // 发起处界面已销毁：原文一个字都不再落地。
  }
  if (result.status != MemoryActionStatus.success || result.text == null) {
    showMemoryActionResult(context, result);
    return;
  }
  final deliver = onRevealed;
  if (deliver != null) {
    deliver(result.text!);
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => _RevealDialog(text: result.text!),
  );
}

/// 直接生效的控制动作（冻结 / 恢复使用 / 解除禁提）。
Future<void> _runDirect(
  BuildContext context, {
  required Future<MemoryActionResult> Function(String id) run,
  required String itemId,
}) async {
  final result = await run(itemId);
  if (!context.mounted) {
    return; // 发起处界面已销毁：不再挂结果横幅。
  }
  showMemoryActionResult(context, result);
}

/// 禁提确认流程（T25 定稿）：先明确确认，取消不产生任何动作。
Future<void> _runBanFlow(
  BuildContext context, {
  required MemoryCenterViewModel viewModel,
  required String itemId,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => const _BanConfirmDialog(),
  );
  if (confirmed != true) {
    return;
  }
  final result = await viewModel.ban(itemId);
  if (!context.mounted) {
    return; // 发起处界面已销毁：不再挂结果横幅。
  }
  showMemoryActionResult(context, result);
}

/// 删除流程：先取准确影响范围，展示后确认执行；影响范围取不到
/// （条目已变化）时如实告知，不执行删除。
Future<void> _runDeleteFlow(
  BuildContext context, {
  required MemoryCenterViewModel viewModel,
  required String itemId,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) =>
        _DeletePreviewDialog(impact: viewModel.deletePreview(itemId)),
  );
  if (confirmed != true) {
    return;
  }
  final result = await viewModel.delete(itemId);
  if (!context.mounted) {
    return; // 发起处界面已销毁：不再挂结果横幅。
  }
  showMemoryActionResult(context, result);
}

/// 动作结果横幅（三态共用一份呈现）：中性面板底，只有失败态把前景
/// 换成 danger。依据是 design-system §1 三色纪律的通则：暗红住「破坏
/// 性操作」与「故障/失败态」两类，某个动作没成属后者（决策日志第五
/// 轮 #15）。partial 既非破坏也非故障，不借危险红，三态的分别由它本
/// 来就写明白的文案承担（#12）。横幅本身经 [showQiyuFadingNotice]
/// 之后的 5 秒渐隐链路展示。
void showMemoryActionResult(BuildContext context, MemoryActionResult result) {
  final failed = result.status == MemoryActionStatus.failed;
  // 关联扩展条数（裁定票 03）：控制生效时若同时覆盖了其它说法，如实
  // 告诉用户——「宁多勿漏」的保守方向要摆在明处，不悄悄多屏蔽。
  final base = memoryActionMessage(context, result.message);
  final message = result.aliasCount > 0
      ? qiyuIsEnNow(context)
            ? '$base ${result.aliasCount} similar expressions were also included.'
            : '$base同时纳入 ${result.aliasCount} 条相近表述。'
      : base;
  showQiyuFadingNotice(
    context,
    message,
    key: const Key('memory-action-result'),
    foregroundColor: failed ? QiyuColors.danger : null,
  );
}

/// 条目操作按钮组（ticket 20；架构深化 ticket 08 起由共享动作计划
/// 驱动）：把当下在场的动作**常驻**摆在条目上，不再收进「⋯」菜单——
/// 记忆控制权是产品的信任承诺，必须随时看得见（design-system §8 补充
/// 约定、Spec Implementation Decision 14、决策日志第二轮 4）。
///
/// 在场与可点一律取 [MemoryActionPlan]；呈现是次要色图标按钮 + 悬停
/// 提亮，取值在主题层 [qiyuQuietIconButtonStyle]。
class MemoryActionButtons extends StatelessWidget {
  const MemoryActionButtons({
    super.key,
    required this.itemId,
    required this.control,
    required this.masked,
    this.editable = false,
    this.currentText,
  });

  final String itemId;
  final MemoryControlStatus? control;
  final bool masked;

  /// 是否提供修正：语义与取值边界见 [MemoryItemActionState.editable]，
  /// 这里只作透传。
  final bool editable;

  /// 修正对话框的预填原文。
  final String? currentText;

  @override
  Widget build(BuildContext context) {
    final acting = context.watch<MemoryCenterViewModel>().acting;
    final plan = MemoryActionPlan(
      state: MemoryItemActionState(
        control: control,
        masked: masked,
        editable: editable,
      ),
      busy: acting,
    );
    // Wrap 而不是 Row：这一组按钮的总宽度等于颗数乘以各自的最小触摸宽度，
    // 自身不会收缩；外层条目头部给不出那么多（极窄窗口、字号放大）时，
    // 宁可让它行内换行，也不要把外层撑成 RenderFlex 溢出——一颗都不许丢。
    // spacing 显式写 0：颗与颗之间只许各自焦点环的 3px 留白相邻，不许容器再往
    // 里塞间距——外层那一处 8 是簇与簇之间的呼吸位，套到颗上四颗就凭空多出
    // 24px。相邻两颗的左边缘距离因此是 54 = 一颗的固有宽 48 + 左右焦点环各 3，
    // 这 6px 是**本容器自己的画法要求**。相邻两颗的 x 距离由
    // test/memory_view_test.dart 的「宽屏下条目头部保持芯片在左、时间与操作
    // 贴右」逐对量着锁住。
    return Wrap(
      spacing: 0,
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final action in plan.offeredActions)
          QiyuFocusRingScope(
            borderRadius: QiyuRadii.circleBorder,
            // tooltip 不是无障碍标签：IconButton 把它交给 MaterialTooltip，
            // 最终只落在语义节点的 tooltip 属性上，label 仍是空的，按
            // bySemanticsLabel 读不到——这条事实由 test/accessibility_test.dart
            // 的「tooltip 只是语义节点的 tooltip 属性」探针用例锁住。触屏没有
            // hover，动作名一律用与 tooltip 同一份文案显式带进语义树，并合成
            // 一个按钮节点。
            child: MergeSemantics(
              child: IconButton(
                key: Key('memory-action-$itemId-${action.name}'),
                onPressed: plan.enabled(action)
                    ? () => unawaited(
                        runMemoryAction(
                          context,
                          action: action,
                          itemId: itemId,
                          currentText: currentText,
                        ),
                      )
                    : null,
                tooltip: action.labelFor(context),
                style: qiyuQuietIconButtonStyle(),
                icon: Icon(
                  action.icon,
                  semanticLabel: action.labelFor(context),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _EditDialog extends StatefulWidget {
  const _EditDialog({required this.initial});

  final String initial;

  @override
  State<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<_EditDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(MemoryLabel.editTitle.of(context)),
      content: TextField(
        key: const Key('memory-edit-field'),
        controller: _controller,
        autofocus: true,
        maxLines: 3,
        maxLength: 120,
        decoration: InputDecoration(hintText: MemoryLabel.editHint.of(context)),
      ),
      actions: [
        QiyuFocusRingScope(
          borderRadius: QiyuRadii.circleBorder,
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(MemoryLabel.cancel.of(context)),
          ),
        ),
        QiyuFocusRingScope(
          borderRadius: QiyuRadii.circleBorder,
          child: TextButton(
            key: const Key('memory-edit-save'),
            onPressed: () => Navigator.of(context).pop(_controller.text),
            child: Text(MemoryLabel.save.of(context)),
          ),
        ),
      ],
    );
  }
}

/// 禁提确认对话框（T25 定稿）。
class _BanConfirmDialog extends StatelessWidget {
  const _BanConfirmDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(MemoryLabel.banTitle.of(context)),
      content: Text(MemoryLabel.banDescription.of(context)),
      actions: [
        QiyuFocusRingScope(
          borderRadius: QiyuRadii.circleBorder,
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(MemoryLabel.notNow.of(context)),
          ),
        ),
        QiyuFocusRingScope(
          borderRadius: QiyuRadii.circleBorder,
          child: TextButton(
            key: const Key('memory-ban-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(MemoryLabel.banAction.of(context)),
          ),
        ),
      ],
    );
  }
}

/// 临时揭示对话框：原文只作本次展示，超时自动关闭；关闭即重新
/// 遮罩。
class _RevealDialog extends StatefulWidget {
  const _RevealDialog({required this.text});

  final String text;

  @override
  State<_RevealDialog> createState() => _RevealDialogState();
}

class _RevealDialogState extends State<_RevealDialog> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(revealTimeout, () {
      if (mounted) {
        Navigator.of(context).pop();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('memory-reveal-dialog'),
      title: Text(MemoryLabel.revealTitle.of(context)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 不提供选择复制：敏感原文只作本次呈现，不进剪贴板。
          Text(widget.text),
          const SizedBox(height: 8),
          Text(
            MemoryLabel.revealDescription.of(context),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        QiyuFocusRingScope(
          borderRadius: QiyuRadii.circleBorder,
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(MemoryLabel.close.of(context)),
          ),
        ),
      ],
    );
  }
}

/// 删除确认对话框：先呈现只读的影响范围预览，确认后返回 true。
class _DeletePreviewDialog extends StatelessWidget {
  const _DeletePreviewDialog({required this.impact});

  final Future<MemoryDeleteImpact?> impact;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(MemoryLabel.deleteTitle.of(context)),
      content: FutureBuilder<MemoryDeleteImpact?>(
        future: impact,
        builder: (context, snapshot) {
          if (!snapshot.hasData && !snapshot.hasError) {
            return SizedBox(
              height: 80,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 8),
                    Text(MemoryLabel.checkingImpact.of(context)),
                  ],
                ),
              ),
            );
          }
          final preview = snapshot.data;
          if (preview == null) {
            return Text(MemoryLabel.itemGone.of(context));
          }
          return ConstrainedBox(
            // 上限而非定宽：窄窗口下随对话框收缩，不溢出（ticket 24）。
            // 内层用 Column 而非视口类列表（对话框要测量内容固有尺寸，
            // ListView 无法参与），外裹 SingleChildScrollView 兜住
            // 字号放大或小窗下的超高内容，与记忆控制总览对话框同模式。
            constraints: const BoxConstraints(
              maxWidth: QiyuLayout.evidenceDialogMaxWidth,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in preview.lines)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(line),
                    ),
                ],
              ),
            ),
          );
        },
      ),
      actions: [
        QiyuFocusRingScope(
          borderRadius: QiyuRadii.circleBorder,
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(MemoryLabel.notNow.of(context)),
          ),
        ),
        FutureBuilder<MemoryDeleteImpact?>(
          future: impact,
          builder: (context, snapshot) {
            final ready = snapshot.hasData && snapshot.data != null;
            return QiyuFocusRingScope(
              borderRadius: QiyuRadii.circleBorder,
              child: TextButton(
                key: const Key('memory-delete-confirm'),
                onPressed: ready ? () => Navigator.of(context).pop(true) : null,
                child: Text(MemoryLabel.confirmDelete.of(context)),
              ),
            );
          },
        ),
      ],
    );
  }
}
