import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../theme/qiyu_theme.dart';
import '../../theme/qiyu_tokens.dart';
import '../chat/local_chat_view_model.dart';
import 'qiyu_widgets.dart';

/// 连接状态（design-system §5、Spec Implementation Decisions 第 8 条）：
/// 侧边栏/抽屉**底部**一枚 6px 中性小圆点 + 一行 13px `muted` 文案
/// 「栖语在本机」，告诉用户对话没出这台机器。
///
/// 三色纪律：正常态**不着紫、不用 danger**（圆点取 `muted`，无发光）；只有
/// 本机 Host 健康探测失败时圆点与文案**同时**转 `danger`，文案换成可点重试
/// 的措辞，点击立即重新探测。数据源是既有 `LocalChatViewModel` 已经在跑的
/// `HostConnectionProbe`（2s 轮询），这里不新增任何网络调用路径。
///
/// **不谎报**：「栖语在本机」是一句结论，只有真探到 Host 在才可以说。还没有
/// 任何一次探测结果（首轮探测未回、或本页被脱离 `LocalChatViewModel` 单独
/// pump）时，这里呈现的是同一套中性形态（6px muted 圆点 + 13px muted 文字，
/// **不加第三种颜色、不加中间态视觉**）配上诚实措辞「正在确认本机连接」，
/// 而不是拿正常态占位。
class QiyuConnectionStatus extends StatefulWidget {
  const QiyuConnectionStatus({super.key});

  /// 正常态文案（定案原文，不得同义改写）。
  static const String normalLabel = '栖语在本机';

  /// 探测失败态文案：可点重试的措辞。
  static const String failedLabel = '连不上本机，点此重试';

  /// 还没探过一次时的文案：不宣称正常，也不宣称故障。形态与正常态完全同款
  /// （中性圆点 + `muted` 次要字），只是措辞把结论换成进行时。
  static const String probingLabel = '正在确认本机连接';

  @override
  State<QiyuConnectionStatus> createState() => _QiyuConnectionStatusState();
}

class _QiyuConnectionStatusState extends State<QiyuConnectionStatus> {
  /// 失败态才进焦点链（正常态不是操作）；节点自己持有并释放。
  final _retryFocusNode = FocusNode(debugLabel: 'conn-status-retry');

  @override
  void dispose() {
    _retryFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 缺 LocalChatViewModel 时（本页被单独 pump）等同于「还没探过」：
    // 中性呈现、不报错，但也**不**替它宣称本机正常。兜底的 try/catch 与
    // 导航壳共用 [maybeProvider] 那一处。
    final viewModel = maybeProvider(() => context.watch<LocalChatViewModel>());
    final failed = viewModel != null && viewModel.hostStopped;
    final probing = viewModel == null || !viewModel.hostStatusKnown;
    final label = failed
        ? QiyuConnectionStatus.failedLabel
        : probing
        ? QiyuConnectionStatus.probingLabel
        : QiyuConnectionStatus.normalLabel;
    final color = failed ? QiyuColors.danger : QiyuColors.muted;

    final row = Row(
      children: [
        Container(
          key: const Key('conn-status-dot'),
          width: QiyuLayout.connectionDotSize,
          height: QiyuLayout.connectionDotSize,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: QiyuSpacing.xs),
        Expanded(
          child: Text(
            label,
            key: const Key('conn-status-text'),
            overflow: TextOverflow.ellipsis,
            style: QiyuTypography.secondary.copyWith(color: color),
          ),
        ),
      ],
    );

    final padded = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: QiyuLayout.navItemPaddingHorizontal,
        vertical: QiyuSpacing.xs,
      ),
      child: failed
          ? QiyuFocusRing(
              focusNode: _retryFocusNode,
              child: InkWell(
                key: const Key('conn-status-retry'),
                focusNode: _retryFocusNode,
                borderRadius: QiyuRadii.cardBorder,
                // 点一下重新探测：不弹窗、不解释，恢复后圆点自己变回中性。
                onTap: () => viewModel.checkHostNow(),
                child: row,
              ),
            )
          : row,
    );

    return Semantics(
      key: const Key('conn-status'),
      label: label,
      button: failed,
      child: padded,
    );
  }
}
