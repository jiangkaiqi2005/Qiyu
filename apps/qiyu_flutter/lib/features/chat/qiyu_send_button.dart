import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/qiyu_icons.dart';
import '../../theme/qiyu_tokens.dart';
import '../shell/qiyu_widgets.dart';
import '../shell/qiyu_ui_locale.dart';
import '../accessibility.dart';

/// 发送按钮（design-system §8 组件 4、决策日志第三轮 4）：圆形、半透明
/// 玻璃紫（`accentGlassA → accentGlassB` 渐变 + 背景模糊 8px）、`onAccent`
/// 白色上箭头；**无描边、无白色高光**，只留极淡紫色光晕。生成中变停止钮。
///
/// 键名沿用既有测试契约：`chat-send` / `chat-stop`（按 `sending` 切换）。
class QiyuSendButton extends StatefulWidget {
  const QiyuSendButton({
    super.key,
    required this.sending,
    required this.onPressed,
  });

  final bool sending;
  final VoidCallback onPressed;

  @override
  State<QiyuSendButton> createState() => _QiyuSendButtonState();
}

class _QiyuSendButtonState extends State<QiyuSendButton> {
  final _focusNode = FocusNode(debugLabel: 'chat-send');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (qiyuAndroidTouch) {
      return QiyuFocusRing(
        focusNode: _focusNode,
        borderRadius: QiyuRadii.circleBorder,
        child: Tooltip(
          message: widget.sending
              ? qiyuStrings(context).stopReply
              : qiyuStrings(context).send,
          child: InkWell(
            key: Key(widget.sending ? 'chat-stop' : 'chat-send'),
            focusNode: _focusNode,
            onTap: widget.onPressed,
            child: SizedBox.square(
              dimension: 48,
              child: Center(child: _surface(_glyph())),
            ),
          ),
        ),
      );
    }
    return QiyuFocusRing(
      focusNode: _focusNode,
      borderRadius: QiyuRadii.circleBorder,
      child: Tooltip(
        message: widget.sending
            ? qiyuStrings(context).stopReply
            : qiyuStrings(context).send,
        child: _surface(
          InkWell(
            key: Key(widget.sending ? 'chat-stop' : 'chat-send'),
            focusNode: _focusNode,
            customBorder: const CircleBorder(),
            onTap: widget.onPressed,
            child: _glyph(),
          ),
        ),
      ),
    );
  }

  Widget _glyph() => SizedBox.square(
    dimension: QiyuLayout.composerIconButtonSize,
    child: Center(
      child: Icon(
        widget.sending ? QiyuIcons.stop : QiyuIcons.arrow_upward,
        size: QiyuIconSpec.sendGlyph,
        color: QiyuColors.onAccent,
      ),
    ),
  );

  Widget _surface(Widget child) => DecoratedBox(
    // 极淡紫色光晕：唯一的紫色出口之一，不给它描边也不给高光。
    decoration: const BoxDecoration(
      shape: BoxShape.circle,
      boxShadow: [
        BoxShadow(
          color: QiyuColors.sendGlow,
          blurRadius: 12,
          offset: Offset(0, 2),
        ),
      ],
    ),
    child: ClipOval(
      child: BackdropFilter(
        // 模糊半径走 token：发送钮一档 8px。
        filter: ui.ImageFilter.blur(
          sigmaX: QiyuGlass.sendButtonBlur,
          sigmaY: QiyuGlass.sendButtonBlur,
        ),
        child: Ink(
          width: QiyuLayout.composerIconButtonSize,
          height: QiyuLayout.composerIconButtonSize,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [QiyuColors.accentGlassA, QiyuColors.accentGlassB],
            ),
          ),
          child: child,
        ),
      ),
    ),
  );
}
