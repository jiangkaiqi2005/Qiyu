import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../theme/qiyu_icons.dart';
import '../../theme/qiyu_theme.dart';
import '../../theme/qiyu_tokens.dart';
import '../accessibility.dart';
import '../shell/qiyu_strings.dart';
import '../shell/qiyu_ui_locale.dart';
import '../shell/qiyu_widgets.dart';
import 'omni_call_controller.dart';

/// 通话状态的一句话文本（聊天页状态栏与跨页通话条共用同一口径，
/// spec 前端摆放：正在聆听／栖语在说话；reason 来自 Host 或本端边界）。
String omniCallStatusLabel(OmniCallController call, QiyuStrings strings) {
  switch (call.phase) {
    case OmniCallPhase.connecting:
      return strings.omniCallConnecting;
    case OmniCallPhase.reconnecting:
      return strings.omniCallReconnecting;
    case OmniCallPhase.ended:
      return call.phaseReason ?? strings.omniCallEnded;
    case OmniCallPhase.active:
      if (call.muted) {
        return strings.omniCallMuted;
      }
      if (call.qiyuSpeaking) {
        return strings.omniCallSpeaking;
      }
      return strings.omniCallListening;
    case OmniCallPhase.idle:
      return strings.omniCallEnded;
  }
}

/// 聊天页通话状态栏（T04:12，spec 前端摆放第二行）：通话期间出现在输入
/// 框上方——状态一句话、闭麦（斜杠麦克风）、挂断（挂断电话图标）。闭麦
/// 只停收音仍可听回答，恢复沿用同一通话；挂断结束整通通话，与「停止回复」
/// 不是一个动作（spec:35）。ended 态保留展示结束原因，重新拨通的入口
/// 回到输入行。由 [LocalChatView] 渲染在 composer 上方的通知条区。
final class QiyuOmniCallStrip extends StatelessWidget {
  const QiyuOmniCallStrip({super.key, required this.call});

  final OmniCallController call;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: call,
      builder: (context, _) {
        if (call.phase == OmniCallPhase.idle) {
          return const SizedBox.shrink();
        }
        final strings = qiyuStrings(context);
        final active = call.phase == OmniCallPhase.active;
        return Padding(
          key: const Key('omni-call-strip'),
          padding: const EdgeInsets.fromLTRB(
            QiyuSpacing.lg,
            QiyuSpacing.xs,
            QiyuSpacing.md,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    omniCallStatusLabel(call, strings),
                    key: const Key('omni-call-status-text'),
                    overflow: TextOverflow.ellipsis,
                    style: QiyuTypography.of(context).secondary.copyWith(
                      color: call.muted ? QiyuColors.muted : QiyuColors.ink,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: QiyuSpacing.sm),
              IconButton(
                key: const Key('omni-strip-mute'),
                tooltip: call.muted
                    ? strings.omniCallUnmuteAction
                    : strings.omniCallMuteAction,
                onPressed: active ? call.toggleMute : null,
                color: QiyuColors.muted,
                icon: Icon(call.muted ? QiyuIcons.mic_off : QiyuIcons.mic),
                iconSize: QiyuIconSpec.size,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints: BoxConstraints.tightFor(
                  width: qiyuAndroidTouch
                      ? 48
                      : QiyuLayout.composerIconButtonSize,
                  height: qiyuAndroidTouch
                      ? 48
                      : QiyuLayout.composerIconButtonSize,
                ),
              ),
              IconButton(
                key: const Key('omni-strip-end'),
                tooltip: strings.omniCallHangupAction,
                onPressed: call.callInProgress
                    ? () => unawaited(call.end())
                    : null,
                color: QiyuColors.ink,
                icon: const Icon(QiyuIcons.call_end),
                iconSize: QiyuIconSpec.size,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints: BoxConstraints.tightFor(
                  width: qiyuAndroidTouch
                      ? 48
                      : QiyuLayout.composerIconButtonSize,
                  height: qiyuAndroidTouch
                      ? 48
                      : QiyuLayout.composerIconButtonSize,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 跨页通话条（T04:13）：活动通话进入记忆／历史／设置等其他页面时，
/// 页面底部保留同语义的简短通话条——状态（点回聊天页）、闭麦、挂断。
/// 不加悬浮球、不建通话页；聊天页不渲染本条（聊天页的通话控件在
/// composer 上方的状态栏里，两处不叠加）。
final class QiyuOmniCallBar extends StatelessWidget {
  const QiyuOmniCallBar({super.key});

  @override
  Widget build(BuildContext context) {
    final call = maybeProvider(() => context.read<OmniCallController>());
    if (call == null) {
      return const SizedBox.shrink();
    }
    return AnimatedBuilder(
      animation: call,
      builder: (context, _) {
        if (!call.callInProgress) {
          return const SizedBox.shrink();
        }
        final strings = qiyuStrings(context);
        return Semantics(
          container: true,
          label: omniCallStatusLabel(call, strings),
          // 条由壳渲染在页面 Scaffold 之外（Column 底部），自带一层透明
          // Material 供 InkWell 出墨，不再依赖页面树。
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              key: const Key('omni-call-bar'),
              decoration: const BoxDecoration(
                color: QiyuColors.night,
                border: Border(
                  top: BorderSide(
                    width: QiyuLine.hairline,
                    color: QiyuColors.line,
                  ),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(
                QiyuSpacing.lg,
                QiyuSpacing.xs,
                QiyuSpacing.sm,
                QiyuSpacing.xs,
              ),
              child: SafeArea(
                top: false,
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        key: const Key('omni-callbar-status'),
                        onTap: () => context.go('/chat'),
                        borderRadius: QiyuRadii.smallBorder,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: QiyuSpacing.sm,
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                QiyuIcons.graphic_eq,
                                size: 16,
                                color: QiyuColors.muted,
                              ),
                              const SizedBox(width: QiyuSpacing.xs),
                              Expanded(
                                child: Text(
                                  omniCallStatusLabel(call, strings),
                                  key: const Key('omni-callbar-status-text'),
                                  overflow: TextOverflow.ellipsis,
                                  style: QiyuTypography.of(
                                    context,
                                  ).secondary.copyWith(color: QiyuColors.ink),
                                ),
                              ),
                              const SizedBox(width: QiyuSpacing.xs),
                              Text(
                                strings.omniCallBackToChat,
                                style: QiyuTypography.of(
                                  context,
                                ).secondary.copyWith(color: QiyuColors.muted),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: QiyuSpacing.sm),
                    IconButton(
                      key: const Key('omni-callbar-mute'),
                      tooltip: call.muted
                          ? strings.omniCallUnmuteAction
                          : strings.omniCallMuteAction,
                      onPressed: call.toggleMute,
                      color: QiyuColors.muted,
                      icon: Icon(
                        call.muted ? QiyuIcons.mic_off : QiyuIcons.mic,
                      ),
                      iconSize: QiyuIconSpec.size,
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      constraints: BoxConstraints.tightFor(
                        width: qiyuAndroidTouch
                            ? 48
                            : QiyuLayout.composerIconButtonSize,
                        height: qiyuAndroidTouch
                            ? 48
                            : QiyuLayout.composerIconButtonSize,
                      ),
                    ),
                    IconButton(
                      key: const Key('omni-callbar-end'),
                      tooltip: strings.omniCallHangupAction,
                      onPressed: () => unawaited(call.end()),
                      color: QiyuColors.muted,
                      icon: const Icon(QiyuIcons.call_end),
                      iconSize: QiyuIconSpec.size,
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      constraints: BoxConstraints.tightFor(
                        width: qiyuAndroidTouch
                            ? 48
                            : QiyuLayout.composerIconButtonSize,
                        height: qiyuAndroidTouch
                            ? 48
                            : QiyuLayout.composerIconButtonSize,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
