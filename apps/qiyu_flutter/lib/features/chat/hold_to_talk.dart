import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../shell/qiyu_ui_locale.dart';

import 'voice_input_controller.dart';

/// 标准长按识别负责起录，原始指针只负责取消和排除额外手指。
class HoldToTalk extends StatefulWidget {
  const HoldToTalk({super.key, required this.voice, required this.beforeStart});

  final VoiceInputController voice;
  final VoidCallback beforeStart;

  @override
  State<HoldToTalk> createState() => _HoldToTalkState();
}

class _HoldToTalkState extends State<HoldToTalk> with WidgetsBindingObserver {
  static const cancelDistance = 48.0;
  int? _pointer;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _cancelled = true;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _start() {
    if (_cancelled || widget.voice.status != VoiceInputStatus.idle) return;
    widget.beforeStart();
    unawaited(widget.voice.startRecording(holdToTalk: true));
  }

  void _cancel() {
    _cancelled = true;
    if (widget.voice.status == VoiceInputStatus.preparing ||
        widget.voice.status == VoiceInputStatus.recording) {
      widget.voice.discard();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.voice,
      builder: (context, _) {
        final strings = qiyuStrings(context);
        final voice = widget.voice;
        final active = voice.status == VoiceInputStatus.recording;
        final label = active
            ? (voice.cancelOnRelease
                  ? strings.releaseToCancel
                  : strings.releaseToSend)
            : voice.status == VoiceInputStatus.preparing
            ? strings.preparingMicrophone
            : strings.holdToTalk;
        return Semantics(
          button: true,
          excludeSemantics: true,
          label: label,
          customSemanticsActions: {
            if (voice.status == VoiceInputStatus.idle)
              CustomSemanticsAction(label: strings.startRecording): () {
                _cancelled = false;
                _start();
              },
            if (active)
              CustomSemanticsAction(label: strings.finishRecording):
                  voice.finishHold,
            if (active || voice.status == VoiceInputStatus.preparing)
              CustomSemanticsAction(label: strings.cancelRecording): _cancel,
          },
          child: Listener(
            onPointerDown: (event) {
              if (_pointer != null) {
                _cancel();
              } else {
                _pointer = event.pointer;
                _cancelled = false;
              }
            },
            onPointerUp: (event) {
              if (event.pointer == _pointer) _pointer = null;
            },
            onPointerCancel: (event) {
              if (event.pointer == _pointer) {
                _pointer = null;
                _cancel();
              }
            },
            child: GestureDetector(
              key: const Key('voice-hold'),
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onLongPressStart: (_) => _start(),
              onLongPressMoveUpdate: (event) {
                if (_cancelled) return;
                setState(
                  () => voice.cancelOnRelease =
                      event.offsetFromOrigin.dy <= -cancelDistance,
                );
              },
              onLongPressEnd: (_) {
                if (!_cancelled) voice.finishHold();
              },
              onLongPressCancel: _cancel,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Center(child: Text(label, textAlign: TextAlign.center)),
              ),
            ),
          ),
        );
      },
    );
  }
}
