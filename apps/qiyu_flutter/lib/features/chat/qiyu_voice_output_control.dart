import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/qiyu_icons.dart';
import '../../theme/qiyu_tokens.dart';
import '../accessibility.dart';
import '../shell/qiyu_widgets.dart';
import 'local_chat_view_model.dart';
import 'voice_output_controller.dart';

/// 聊天页工具条上的朗读开关与音量弹层：独立功能件，与本页其余渲染零耦合
/// ——页面只在工具条构造一次，弹层的开关分档、滑块、静音与遮罩收起等
/// 内部状态全部收在本模块里。
class QiyuVoiceOutputControl extends StatefulWidget {
  const QiyuVoiceOutputControl({super.key, required this.viewModel});

  final LocalChatViewModel viewModel;

  @override
  State<QiyuVoiceOutputControl> createState() =>
      _QiyuVoiceOutputControlState();
}

class _QiyuVoiceOutputControlState extends State<QiyuVoiceOutputControl> {
  final _overlayController = OverlayPortalController();
  final _link = LayerLink();

  /// 焦点节点由本控件持有并释放，同时交给自绘键盘焦点环与 IconButton
  /// （§9：工具条上的图标按钮也要有带 offset 的实线外环，且只响应键盘态）。
  final _focusNode = FocusNode(debugLabel: 'voice-output-toggle');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final viewModel = widget.viewModel;
    final voiceOutput = viewModel.voiceOutput;
    return CompositedTransformTarget(
      link: _link,
      child: ListenableBuilder(
        listenable: voiceOutput,
        builder: (context, _) {
          final isMuted =
              !viewModel.voiceOutputEnabled || voiceOutput.volume == 0;
          final icon = isMuted
              ? QiyuIcons.volume_off
              : (voiceOutput.volume < 0.5
                    ? QiyuIcons.volume_down
                    : QiyuIcons.volume_up);
          return OverlayPortal(
            controller: _overlayController,
            overlayChildBuilder: (context) {
              return Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _overlayController.hide(),
                      child: const SizedBox.expand(),
                    ),
                  ),
                  CompositedTransformFollower(
                    link: _link,
                    targetAnchor: Alignment.bottomCenter,
                    followerAnchor: Alignment.topCenter,
                    offset: const Offset(0, 6),
                    child: _VolumePopupCard(
                      viewModel: viewModel,
                      voiceOutput: voiceOutput,
                    ),
                  ),
                ],
              );
            },
            child: QiyuFocusRing(
              focusNode: _focusNode,
              borderRadius: QiyuRadii.circleBorder,
              child: IconButton(
                key: Key(
                  viewModel.voiceOutputEnabled
                      ? 'voice-output-toggle-on'
                      : 'voice-output-toggle-off',
                ),
                focusNode: _focusNode,
                color: isMuted ? theme.colorScheme.onSurfaceVariant : null,
                style: qiyuAndroidTouchStyle,
                tooltip: viewModel.voiceOutputEnabled
                    ? '朗读音量与静音调节'
                    : '语音朗读已关闭，点击开启与调节',
                icon: Icon(icon),
                onPressed: () {
                  _overlayController.toggle();
                },
              ),
            ),
          );
        },
      ),
    );
  }
}

class _VolumePopupCard extends StatelessWidget {
  const _VolumePopupCard({required this.viewModel, required this.voiceOutput});

  final LocalChatViewModel viewModel;
  final VoiceOutputController voiceOutput;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isMuted = !viewModel.voiceOutputEnabled || voiceOutput.volume == 0;
    final percent = isMuted ? 0 : (voiceOutput.volume * 100).round();

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 72,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: QiyuRadii.cardBorder,
          border: Border.all(color: theme.colorScheme.outlineVariant),
          boxShadow: [
            BoxShadow(
              color: theme.shadowColor.withValues(alpha: 0.25),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              height: 120,
              width: 32,
              child: RotatedBox(
                quarterTurns: 3,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 6,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 8,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 14,
                    ),
                    activeTrackColor: theme.colorScheme.primary,
                    thumbColor: theme.colorScheme.primary,
                    inactiveTrackColor: theme.colorScheme.surfaceContainer,
                  ),
                  child: Slider(
                    key: const Key('voice-output-volume-slider'),
                    value: isMuted ? 0.0 : voiceOutput.volume,
                    min: 0.0,
                    max: 1.0,
                    onChanged: (val) {
                      voiceOutput.setVolume(val);
                      if (!viewModel.voiceOutputEnabled && val > 0) {
                        unawaited(viewModel.toggleVoiceOutput());
                      }
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(height: QiyuSpacing.xs),
            Text(
              '$percent%',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.bold,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 6),
            const Divider(height: 1),
            const SizedBox(height: 2),
            IconButton(
              key: const Key('voice-output-popover-mute-button'),
              iconSize: 22,
              visualDensity: VisualDensity.compact,
              tooltip: isMuted ? '解除静音' : '静音',
              color: isMuted ? theme.colorScheme.onSurfaceVariant : null,
              icon: Icon(isMuted ? QiyuIcons.volume_off : QiyuIcons.volume_up),
              onPressed: () => unawaited(viewModel.toggleVoiceOutput()),
            ),
          ],
        ),
      ),
    );
  }
}
