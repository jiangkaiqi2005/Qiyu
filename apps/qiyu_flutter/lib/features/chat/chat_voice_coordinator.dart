import 'dart:async';

import 'local_chat_view_model.dart';
import 'voice_input_controller.dart';
import 'voice_recorder_platform.dart';

/// 聊天页内未提交语音的所有者；UI 仍拥有挂载、草稿与焦点。
final class ChatVoiceCoordinator {
  ChatVoiceCoordinator({
    required this.viewModel,
    required this.input,
    required this.android,
    required this.hasComposer,
    required VoiceRecorderPlatform recorder,
  }) {
    if (android) {
      viewModel.voiceOutput.isMicrophoneInUse = _isMicrophoneInUse;
      if (recorder is InterruptibleVoiceRecorderPlatform) {
        _interruptions = (recorder as InterruptibleVoiceRecorderPlatform)
            .interruptions
            .listen((_) => cancelForPage());
      }
    }
  }

  final LocalChatViewModel viewModel;
  final VoiceInputController input;
  final bool android;
  final bool Function() hasComposer;
  StreamSubscription<void>? _interruptions;
  Completer<void>? _pending;
  void Function()? onPendingChanged;

  bool get hasPending => _pending != null;
  bool get hasUnsubmitted =>
      hasPending ||
      input.status == VoiceInputStatus.preparing ||
      input.status == VoiceInputStatus.recording ||
      input.status == VoiceInputStatus.transcribing ||
      input.status == VoiceInputStatus.retryable;

  bool _isMicrophoneInUse() => input.isMicrophoneInUse;

  Future<void> sendTranscribed(
    String text, {
    required bool Function() isMounted,
    required void Function() onCommitted,
    required Future<void>? Function(ChatSendResult result) onFinished,
  }) async {
    final pending = android ? Completer<void>() : null;
    if (android && _pending != null) return;
    if (pending != null) {
      _pending = pending;
      onPendingChanged?.call();
    }
    final result = await viewModel.sendWhenIdle(
      text,
      cancelled: pending?.future,
      isCancelled: pending == null ? null : () => pending.isCompleted,
      onCommitted: () {
        if (pending != null && isMounted()) {
          _pending = null;
          onPendingChanged?.call();
        }
        onCommitted();
      },
    );
    if (pending?.isCompleted ?? false) return;
    if (pending != null && identical(_pending, pending)) {
      _pending = null;
      if (isMounted()) onPendingChanged?.call();
    }
    final finishing = onFinished(result);
    if (finishing != null) await finishing;
  }

  void cancelUnsubmitted() {
    if (_pending != null) {
      _pending!.complete();
      _pending = null;
      onPendingChanged?.call();
    }
    // idle 也可能处于转写完成通知与进入待发之间，仍须作废尝试。
    if (input.status == VoiceInputStatus.idle || hasUnsubmitted) {
      input.discard();
    }
  }

  /// 页面在 composer 缺席时原本不取消输入，保留这个挂载窗口。
  void cancelForPage() {
    if (hasComposer()) cancelUnsubmitted();
  }

  void leaveRoute() {
    cancelForPage();
    viewModel.voiceOutput.stopAllForLeavingPage();
  }

  void enterBackground() {
    cancelForPage();
    viewModel.voiceOutput.interruptOutput();
  }

  void escape() {
    viewModel.voiceOutput.stopAll();
    if (android) {
      cancelUnsubmitted();
    } else {
      input.handleEscape();
    }
  }

  void startRecording() {
    final output = viewModel.voiceOutput;
    output.stopAll();
    // 自动收尾没有第二次手势，开始录音时先保留回复朗读许可。
    if (viewModel.voiceOutputEnabled) {
      output.prepareForUserInitiatedPlayback();
    }
    input.handleMicTap();
  }

  void finishRecording() {
    viewModel.voiceOutput.prepareForUserInitiatedPlayback();
    input.handleMicTap();
  }

  void retryTranscription() {
    final output = viewModel.voiceOutput;
    output.stopAll();
    output.prepareForUserInitiatedPlayback();
    input.handleMicTap();
  }

  void beforeHoldToTalk() => viewModel.voiceOutput.stopAll();

  /// 输入框销毁只取消待发，不扩大为丢弃录音或停止朗读。
  void detachComposer() {
    _pending?.complete();
    _pending = null;
    onPendingChanged = null;
  }

  void unsubscribe() => unawaited(_interruptions?.cancel());

  void dispose() {
    if (viewModel.voiceOutput.isMicrophoneInUse == _isMicrophoneInUse) {
      viewModel.voiceOutput.isMicrophoneInUse = null;
    }
  }
}
