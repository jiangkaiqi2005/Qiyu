import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/qiyu_icons.dart';
import '../../theme/qiyu_theme.dart';
import '../../theme/qiyu_tokens.dart';
import '../shell/qiyu_widgets.dart';
import 'local_chat_client.dart';
import 'local_chat_view_model.dart';
import 'qiyu_send_button.dart';
import 'voice_input_controller.dart';

/// 输入框里按 Enter 发送；Shift+Enter / Ctrl+Enter 插入软换行。
final class _SendChatIntent extends Intent {
  const _SendChatIntent();
}

final class _InsertLineBreakIntent extends Intent {
  const _InsertLineBreakIntent();
}

/// Esc 在语音输入各状态下的语义：录音中丢弃、转写中中止、可重试丢弃。
final class _VoiceEscapeIntent extends Intent {
  const _VoiceEscapeIntent();
}

/// 聊天输入模块（design-system §8 组件 5）：合一页输入行的完整职责单位。
///
/// 拥有并收拢输入相关的全部内部状态与生命周期——文本与选区（控制器）、
/// 焦点（FocusNode 与聚焦描边重绘）、输入宽度定位（测量键）、展开状态
/// 与折行测量（同源样式 + 实际宽度 + 光标边距）、快捷键（Enter 发送、
/// Shift/Ctrl+Enter 软换行、Esc 语音语义）以及监听与帧后回调的注册取消。
/// 合一页只负责把它放进空态/聊天态的布局里，并接住三个页面侧回调；
/// 页面经由 [QiyuComposerState] 能做的操作只有「恢复输入焦点」与
/// 「转写文本发送」，FocusNode、测量键与展开状态一律不外露。
///
/// 发送后的清空与失败回填也在这里协调：手打与语音转写沿用各自既有的
/// 判断条件与异步先后（见 [_send]、[QiyuComposerState.sendTranscribed]），
/// 发出的轮次仍走同一个聊天视图模型——这里不建第二套 requestId、消息
/// 列表或发送锁。语音输入/朗读控制器由页面创建并复用传入，不在本模块
/// 重建；麦克风按钮与 Esc 只是它们的展示与分派面。
class QiyuComposer extends StatefulWidget {
  const QiyuComposer({
    super.key,
    required this.viewModel,
    required this.voiceInput,
    required this.onSendStarted,
    required this.onTurnCompleted,
    required this.pushAwayFromChat,
  });

  final LocalChatViewModel viewModel;

  /// 页面创建并拥有的语音输入控制器：麦克风按钮与 Esc 只分派它。
  final VoiceInputController voiceInput;

  /// 发送起点回调（手打与转写共用）：页面据此把消息区拉回贴底。
  final VoidCallback onSendStarted;

  /// 轮次收尾回调：发送成功落定后由页面接手服务异常的分类、频控与弹窗。
  /// 无参——本轮视图模型就是模块持有的 [QiyuComposer.viewModel]，页面
  /// 侧闭包自取，回调不再重复携带。
  final Future<void> Function() onTurnCompleted;

  /// 页面侧导航（停播 + push）：麦克风置灰态引导的「去设置」复用同一口径。
  final void Function(String location) pushAwayFromChat;

  /// M3 compact IconButton 在 tightFor([QiyuLayout.composerIconButtonSize])
  /// 约束下的渲染增量（34 → 40，实测值）：SDK 密度调整的结果，无既有 token 可引。
  static const double _compactIconButtonSizeDelta = 6;

  /// composer 输入行（Row）的静息高，取最高子项（麦克风钮一侧）：
  /// 图标按钮 [QiyuLayout.composerIconButtonSize] + compact 渲染增量
  /// [_compactIconButtonSizeDelta] + 焦点环常驻留白上下
  /// 2×[QiyuLayout.focusRingOffset]。
  ///
  /// 模块对外发布的唯一几何常量：合一页的消息列表据此推导覆盖层的底部
  /// 让位（列表把 composer 当静息占位预留空间）。只用于该推导，**不作
  /// 展开判据**——窄屏字阶下两行内容仍矮于按钮行，按高度判定会漏翻
  /// （见 [QiyuComposerState._updateComposerExpanded]）。
  static const double restingRowHeight = QiyuLayout.composerIconButtonSize +
      _compactIconButtonSizeDelta +
      2 * QiyuLayout.focusRingOffset;

  @override
  State<QiyuComposer> createState() => QiyuComposerState();
}

/// State 对页面暴露的最小操作面：[restoreFocus] 与 [sendTranscribed]。
/// 合一页经由 [GlobalKey] 调用这两个操作；键同时充当空态↔聊天态换位时
/// 的身份键——State 原位保留（GlobalKey 重挂），文本、选区与焦点不因
/// 换布局销毁重建。
class QiyuComposerState extends State<QiyuComposer> {
  /// composer 多行展开态的下沿内边距：上沿保持静息 [QiyuLayout.composerPadding]
  /// 不动——宋体行盒的空隙大头分在文字上方（行高按字体上伸比例分配、CJK 字面
  /// 偏上），视觉上沿自带余量；留白全部补给下沿，让最后一行离圆角远一点
  /// （2026-09-05 用户反馈「上面太宽了，下面太窄了，离圆角太近了」；总留白
  /// 与先前的上下对称方案一致，只是分配不同）。
  static const double _composerExpandedBottomPadding =
      QiyuLayout.composerPadding + 2 * QiyuSpacing.xs;

  /// composer 光标宽度：[_inputField] 显式传给 TextField（渲染不变，Flutter
  /// 默认就是 2.0），展开态判定按它扣排版宽，见 [_updateComposerExpanded]。
  static const double _inputCursorWidth = 2.0;

  final _controller = TextEditingController();

  /// composer 焦点：聚焦态描边取 `composerFocusLine`（紫度 0.13），
  /// 失焦回落到 `line` 发丝线（design-system §8 组件 5）。
  final _focusNode = FocusNode(debugLabel: 'chat-input');

  /// composer 输入框量宽键：展开态判定要按输入框的**实际可用宽度**排版数行，
  /// 按钮列的宽度必须排除在外，所以键挂在输入框本体而不是整行。
  final _composerFieldKey = GlobalKey(debugLabel: 'composer-field');

  /// composer 输入是否多于一行：多于一行即展开，面板下沿加到
  /// [_composerExpandedBottomPadding]（上沿不动）；单行静息分毫不动（列表底部
  /// 让位常量与基线测试的 492/516 都依赖这一点）。
  bool _composerExpanded = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChange);
    // 文本每次变化（打字、IME 组合、程序注入）都可能改变输入行行数。
    _controller.addListener(_updateComposerExpanded);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode
      ..removeListener(_onFocusChange)
      ..dispose();
    super.dispose();
  }

  /// 聚焦描边要跟着焦点重绘：`QiyuGlassPanel` 的装饰走 AnimatedContainer，
  /// `line` ↔ `composerFocusLine` 是 200ms 过渡（reduced-motion 下为 0）。
  void _onFocusChange() {
    if (mounted) setState(() {});
  }

  /// 弹窗「知道了」等页面动作后的焦点返还：模块对外的两个操作之一。
  /// 只请求焦点，不碰文本与选区——调用前的草稿原样保留。
  void restoreFocus() {
    if (!mounted) {
      return;
    }
    _focusNode.requestFocus();
  }

  /// 语音转写出的文字直接发送：与手打共用同一条链路（requestId 幂等、
  /// 乐观插入、失败回填输入框）。栖语正在回复时排队，回复结束即发。
  /// 模块对外的另一个操作：页面把转写回调接进来后由此进入发送协调。
  Future<void> sendTranscribed(String text) async {
    final viewModel = widget.viewModel;
    widget.onSendStarted();
    final sent = await viewModel.sendWhenIdle(text);
    if (!sent &&
        mounted &&
        _controller.text.isEmpty &&
        text.trim().isNotEmpty) {
      _backfillDraft(text);
    }
    if (sent && mounted) {
      await widget.onTurnCompleted();
    }
  }

  Future<void> _send() async {
    final viewModel = widget.viewModel;
    final text = _controller.text;
    if (text.trim().isEmpty) {
      return;
    }
    widget.onSendStarted();
    final sending = viewModel.send(text);
    if (mounted && _controller.text == text) {
      _controller.clear();
    }
    final sent = await sending;
    if (!sent &&
        mounted &&
        _controller.text.isEmpty &&
        !viewModel.messages.any(
          (message) =>
              message.speaker == LocalChatSpeaker.user &&
              message.text == text.trim(),
        )) {
      _backfillDraft(text);
    }
    if (sent && mounted) {
      await widget.onTurnCompleted();
    }
  }

  /// 发送失败的原文回填：文本写回输入框并把光标置尾，等待用户重发。
  /// 手打（[_send]）与转写（[QiyuComposerState.sendTranscribed]）各自的
  /// 守卫条件（输入框是否为空、去重、trim 非空）原样留在调用处，这里只
  /// 收拢「回填 + 光标置尾」这一段同形操作。
  void _backfillDraft(String text) {
    _controller.text = text;
    _controller.selection = TextSelection.collapsed(offset: text.length);
  }

  void _insertLineBreak() {
    final value = _controller.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final nextText = value.text.replaceRange(start, end, '\n');
    _controller.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: start + 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 窗口宽度变化会改折行数与字阶档位（进而改输入行高），这类变化不经过
    // 文本控制器，靠每次 build 补一次帧后核对兜住。
    _updateComposerExpanded();
    final viewModel = widget.viewModel;
    final lineColor = _focusNode.hasFocus
        ? QiyuColors.composerFocusLine
        : QiyuColors.line;
    final bottomPadding = _composerExpanded
        ? _composerExpandedBottomPadding
        : QiyuLayout.composerPadding;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: QiyuSpacing.md),
      child: QiyuStreamWidthBox(
        // composer（design-system §8 组件 5）：毛玻璃胶囊、`line` 发丝描边、
        // 内边距 6（多行展开态下沿再让两档 xs、上沿不动，单行静息不动）、
        // 聚焦描边压到紫度 0.13；占位字 `muted` 且靠 34px 行高居中。
        //
        // `home-go-chat` 沿用退役前首页「去聊天」入口卡的既有测试键：合一页
        // 之后进入对话的动作就是这个输入容器，键位随职责搬过来。
        child: QiyuGlassPanel(
          key: const Key('home-go-chat'),
          blurSigma: QiyuGlass.panelBlur,
          borderColor: lineColor,
          padding: EdgeInsets.fromLTRB(
            QiyuSpacing.md,
            QiyuLayout.composerPadding,
            QiyuLayout.composerPadding,
            bottomPadding,
          ),
          // 输入行本体：Enter 发送 / 软换行 / Esc 的快捷键作用域只包住它。
          child: Shortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.enter): _SendChatIntent(),
              SingleActivator(LogicalKeyboardKey.enter, shift: true):
                  _InsertLineBreakIntent(),
              SingleActivator(LogicalKeyboardKey.enter, control: true):
                  _InsertLineBreakIntent(),
              SingleActivator(LogicalKeyboardKey.escape): _VoiceEscapeIntent(),
            },
            child: Actions(
              actions: {
                _SendChatIntent: CallbackAction<_SendChatIntent>(
                  onInvoke: (intent) {
                    if (!viewModel.sending) {
                      unawaited(_send());
                    }
                    return null;
                  },
                ),
                _InsertLineBreakIntent: CallbackAction<_InsertLineBreakIntent>(
                  onInvoke: (intent) {
                    _insertLineBreak();
                    return null;
                  },
                ),
                _VoiceEscapeIntent: CallbackAction<_VoiceEscapeIntent>(
                  onInvoke: (intent) {
                    // 播放态下 Esc 等同停止按钮（ADR 0002 的打断规则）；
                    // 录音/转写语义不变。
                    viewModel.voiceOutput.stopAll();
                    widget.voiceInput.handleEscape();
                    return null;
                  },
                ),
              },
              child: Row(
                children: [
                  Expanded(
                    child: KeyedSubtree(
                      key: _composerFieldKey,
                      child: _inputField(),
                    ),
                  ),
                  const SizedBox(width: QiyuSpacing.xs),
                  AnimatedBuilder(
                    animation: widget.voiceInput,
                    builder: (context, _) => _voiceMicButton(),
                  ),
                  const SizedBox(width: QiyuSpacing.xs),
                  QiyuSendButton(
                    sending: viewModel.sending,
                    onPressed: viewModel.sending
                        ? () => unawaited(viewModel.stop())
                        : () => unawaited(_send()),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 展开态帧后核对：用与输入框**同源**的字体样式（[_inputTextStyle]）把当前
  /// 文本按输入框实际可用宽度排版，行数 > 1 即展开，只在布尔翻转时 setState。
  ///
  /// 判定必须与真实渲染**双同源**，缺一处软折行边界就会漏判/过判（2026-09-05
  /// 实测：`一`×35+'。' 真实渲染 2 行、判定 1 行，面板停在静息 60 下沿贴边，
  /// 再补一个字符才跳展开——观感即「一个句号和两个句号差太多」）：
  /// - 样式必须与渲染同源：[_inputTextStyle] 按 TextField 的实际装配方向取
  ///   Theme `bodyLarge` merge（机制见其 doc）。裸 `QiyuTypography.body` 少了
  ///   渲染样式自带的 `letterSpacing`，每行会比真实多容约 1 字符；
  /// - 宽度必须扣光标边距：RenderEditable 的实际排版宽比容器窄
  ///   `_caretMargin = 1.0 + cursorWidth`（rendering/editable.dart 的
  ///   `_kCaretGap`），即下方的 `1.0 + _inputCursorWidth`；不扣会在临界长度
  ///   再漏判一格。
  ///
  /// 判据必须是「内容行数」而非「输入行高超过按钮行（[QiyuComposer.restingRowHeight]）」：
  /// 窄屏字阶与浏览器缩放会把单行行盒压到 22px 上下，两行内容（44px）仍矮于
  /// 46px 的按钮行，按高度判定会漏翻——2026-09-05 用户 200% 缩放真机踩中，
  /// 观感即「两行贴边、三行才突然松开，两行和三行差太多」。留白加在输入行
  /// 外层的面板上，不反馈输入框自身宽度，量一次即稳。触发路径：控制器文本
  /// 变化与本模块每次 build（见 initState 与 build）。
  void _updateComposerExpanded() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _composerFieldKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize || box.size.width <= 0) return;
      final painter = TextPainter(
        text: TextSpan(
          text: _controller.text,
          style: _inputTextStyle(context),
        ),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: box.size.width - 1.0 - _inputCursorWidth);
      final expanded = painter.computeLineMetrics().length > 1;
      painter.dispose();
      if (expanded != _composerExpanded) {
        setState(() => _composerExpanded = expanded);
      }
    });
  }

  /// 输入框本体：字色与占位字都来自 token；描边交给外层玻璃面板，
  /// 因此这里显式撤掉 TextField 自己的边框与填充。cursorWidth 显式传
  /// [_inputCursorWidth]（值等于默认），让展开态判定扣的光标边距有同一出处。
  Widget _inputField() {
    return TextField(
      key: const Key('chat-input'),
      controller: _controller,
      focusNode: _focusNode,
      autofocus: true,
      minLines: 1,
      maxLines: 5,
      textInputAction: TextInputAction.newline,
      cursorWidth: _inputCursorWidth,
      style: _inputTextStyle(context),
      decoration: const InputDecoration(
        hintText: '想说点什么…',
        filled: false,
        isDense: true,
        contentPadding: EdgeInsets.zero,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        errorBorder: InputBorder.none,
        focusedErrorBorder: InputBorder.none,
      ),
    );
  }

  /// 输入框文本样式：[_inputField] 与展开态行数判定（[_updateComposerExpanded]）
  /// 必须共用同一份，行数才不会按另一份字体度量排版。
  ///
  /// 构造 = `Theme.of(context).textTheme.bodyLarge` merge `QiyuTypography.body`
  /// + ink，**merge 方向必须 bodyLarge 在前**：TextStyle.merge 是 other 覆盖
  /// this，而主题 `bodyLarge` 经 `Theme.of` 返回前的 Typography englishLike
  /// 2021 几何 merge（theme_data.dart 的 `ThemeData.localize`）后 `inherit` 为
  /// false——TextStyle.merge 对 inherit false 的 other 直接原样返回，反向
  /// merge 会整个丢掉 `QiyuTypography` 当档字阶与 ink 的显式覆盖。正向 merge
  /// 得到的样式自带渲染层的 `letterSpacing: 0.5` 与 `height: 1.5`，再过
  /// TextField 内部的 `bodyLarge.merge(providedStyle)`（text_field.dart 的
  /// `_m3InputStyle`）逐属性不变：渲染零变化，判定从此与渲染同源。
  TextStyle _inputTextStyle(BuildContext context) => Theme.of(context)
      .textTheme
      .bodyLarge!
      .merge(QiyuTypography.of(context).body.copyWith(color: QiyuColors.ink));

  /// 麦克风按钮：置灰态（不支持/未配置）点击只做引导，其余状态按
  /// 控制器状态机分派；转写中禁点（Esc 才是中止入口）。
  ///
  /// 五个状态共用 composer 的 34px 圆形图标按钮规格（design-system §8
  /// 组件 3），键名、tooltip 与状态机语义逐一对应原实现。
  Widget _voiceMicButton() {
    final voice = widget.voiceInput;
    final theme = Theme.of(context);
    final (key, tooltip, icon, color, onPressed) = switch (voice.status) {
      VoiceInputStatus.unsupported || VoiceInputStatus.notConfigured => (
        'voice-mic',
        '语音输入（当前不可用）',
        const Icon(QiyuIcons.mic_off),
        theme.disabledColor,
        _showVoiceGuide,
      ),
      VoiceInputStatus.idle => (
        'voice-mic',
        '语音输入',
        const Icon(QiyuIcons.mic),
        null,
        // 点麦克风她立刻闭嘴（ADR 0002 硬规则）：她的声音不能被录进
        // 转写变成用户在自言自语。
        () {
          final viewModel = widget.viewModel;
          viewModel.voiceOutput.stopAll();
          // 60 秒自动收尾没有第二次点击，必须在开始录音
          // 的用户手势中先为稍后的回复朗读保留许可。
          if (viewModel.voiceOutputEnabled) {
            viewModel.voiceOutput.prepareForUserInitiatedPlayback();
          }
          voice.handleMicTap();
        },
      ),
      VoiceInputStatus.recording => (
        'voice-mic-stop',
        '说完，转成文字',
        const Icon(QiyuIcons.stop_circle),
        theme.colorScheme.error,
        // 转写和聊天都会跨越异步边界；说完的这次点击
        // 是语音闭环最后一个可用的浏览器用户手势。
        () {
          widget.viewModel.voiceOutput.prepareForUserInitiatedPlayback();
          voice.handleMicTap();
        },
      ),
      VoiceInputStatus.transcribing => (
        'voice-mic-busy',
        '正在转文字',
        const SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        null,
        null,
      ),
      VoiceInputStatus.retryable => (
        'voice-mic-retry',
        '重试转写',
        const Icon(QiyuIcons.mic),
        theme.colorScheme.error,
        // 与开始录音同规则：点麦克风即停播清队列。
        () {
          final voiceOutput = widget.viewModel.voiceOutput;
          voiceOutput.stopAll();
          voiceOutput.prepareForUserInitiatedPlayback();
          voice.handleMicTap();
        },
      ),
    };
    return QiyuOwnFocusRing(
      borderRadius: QiyuRadii.circleBorder,
      builder: (context, focusNode) => IconButton(
        key: Key(key),
        focusNode: focusNode,
        tooltip: tooltip,
        color: color,
        onPressed: onPressed,
        icon: icon,
        iconSize: QiyuIconSpec.size,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(
          width: QiyuLayout.composerIconButtonSize,
          height: QiyuLayout.composerIconButtonSize,
        ),
      ),
    );
  }

  Future<void> _showVoiceGuide() async {
    final voice = widget.voiceInput;
    // 置灰态先惰性重查一次：从设置页配好回来点麦克风直接开始说话。
    await voice.refreshConfigured();
    if (!mounted) {
      return;
    }
    if (voice.status == VoiceInputStatus.idle) {
      voice.handleMicTap();
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          voice.status == VoiceInputStatus.unsupported
              ? '当前浏览器不支持语音输入，请换 Chrome 或 Edge。'
              : '还没有配置语音服务，先去设置页填写地址、模型和 Key。',
        ),
        action: voice.status == VoiceInputStatus.unsupported
            ? null
            : SnackBarAction(
                label: '去设置',
                onPressed: () => widget.pushAwayFromChat('/settings'),
              ),
      ),
    );
  }
}
