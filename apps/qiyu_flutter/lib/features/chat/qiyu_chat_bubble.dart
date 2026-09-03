import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../theme/qiyu_icons.dart';
import '../../theme/qiyu_theme.dart';
import '../../theme/qiyu_tokens.dart';
import '../accessibility.dart';
import '../time_format.dart';
import 'qiyu_markdown.dart';

/// 会话气泡：聊天页与历史回看页共用。按 design-system §7 的**单侧气泡**
/// 形态——用户消息右对齐水滴气泡（圆角 20/20/6/20、无描边、面色
/// `bubble-user`），栖语的话**没有气泡**，书页式宋体靠左、行高 1.9。
/// 语义标签带上说话人，屏幕阅读器分得清谁在说（ticket 24）。
class QiyuChatBubble extends StatefulWidget {
  const QiyuChatBubble({
    super.key,
    required this.text,
    required this.fromUser,
    this.isSpeaking = false,
    this.onReplay,
    this.deliveryIndex,
    this.at,
  });

  final String text;
  final bool fromUser;

  /// 这段话正在被朗读（ADR 0002 的「正在朗读」轻量指示）：气泡尾部
  /// 多一行小字与音量图标，读完即消失。
  final bool isSpeaking;

  /// 栖语气泡的重听入口（小喇叭）：点一下立即重读这句（重听=重新
  /// 合成，文字都在）。null（用户气泡、历史回看页）不显示。
  final VoidCallback? onReplay;

  /// 朗读定位序号（同 requestId 内第 N 次交付段）：作重听按钮的可
  /// 访问 key 标识，widget 测试可精确定位。
  final int? deliveryIndex;

  /// 消息时刻（Host 落盘的客观时刻）：消息块下方**外部一行**的次要档
  /// 弱色文字——用户消息右对齐贴气泡尾部，栖语靠左；不参与气泡内布局，
  /// 气泡/文本块本体尺寸不随它显隐变化。鼠标指针默认**完全不渲染**，
  /// 悬停整条消息（含时刻行）才出现；触屏/手写笔指针没有 hover，纯触屏
  /// 平台档以约两成透明度常驻，桌面平台（触屏二合一设备）要轻点消息
  /// 确认——轻点走手势竞技场，滑动滚动列表不算。形态由最近一次落在
  /// 消息上的指针事件驱动——桌面触屏设备（Windows 平板浏览器）不再被
  /// 平台档判成两头落空；尚无指针事件时按 Web 壳层平台档作初始猜测。
  /// null（直播流尚未预显、无时刻数据）不渲染。
  final DateTime? at;

  @override
  State<QiyuChatBubble> createState() => _QiyuChatBubbleState();
}

class _QiyuChatBubbleState extends State<QiyuChatBubble> {
  /// 桌面指针当前是否悬停在整条消息上：时刻行的显隐开关。
  bool _hovering = false;

  /// 最近一次落在消息上的指针类型：触屏判定改走事件驱动，桌面触屏
  /// 设备（Windows 平板浏览器）不再被平台档判成两头落空。null 即
  /// 尚无指针事件，按平台档作初始猜测。
  PointerDeviceKind? _lastPointerKind;

  /// 触屏常驻显现的轻点确认：桌面平台档（含触屏二合一设备）初始不
  /// 显现时刻，要等触屏/手写笔**轻点**消息后才落这一位。轻点走
  /// GestureDetector 的手势竞技场——滑动滚动列表时拖拽识别器胜出、
  /// tap 被否决，滑过的气泡不再被误判成常驻（旧实现裸记
  /// PointerDownEvent，按下即显现且无复位）。纯触屏平台档（见
  /// [_platformDefaultIsTouch]）没有 hover 可依赖，不做这道确认，
  /// 时刻默认常驻。
  bool _touchRevealed = false;

  /// 记录最近一次指针类型；类型没变就不重建（鼠标 hover 事件很密）。
  void _rememberPointerKind(PointerEvent event) {
    if (event.kind != _lastPointerKind) {
      setState(() => _lastPointerKind = event.kind);
    }
  }

  /// 触屏轻点确认：只有 touch/stylus 的 tap 才落常驻显现。GestureDetector
  /// 的 tap 对鼠标左键同样成立，但鼠标档本就有悬停显现，点击不额外
  /// 改变状态。
  void _handleTapped() {
    final kind = _lastPointerKind;
    if (kind == PointerDeviceKind.touch || kind == PointerDeviceKind.stylus) {
      setState(() => _touchRevealed = true);
    }
  }

  /// 平台档初始猜测：Web 壳层 UA 映射——移动端浏览器是 android/iOS，
  /// 桌面浏览器是 windows/macos/linux，与「有没有鼠标」在这个产品里
  /// 一一对应。尚无指针事件时由它定触屏形态与常驻显现的初始值。
  bool get _platformDefaultIsTouch {
    return switch (Theme.of(context).platform) {
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.fuchsia => true,
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => false,
    };
  }

  /// 触屏路径判定：touch/stylus 没有 hover，走常驻淡显；鼠标与触控板
  /// 走悬停显现。尚无指针事件时按平台档取代理（[_platformDefaultIsTouch]）。
  bool get _touchPointer {
    final kind = _lastPointerKind;
    if (kind == null) {
      return _platformDefaultIsTouch;
    }
    return kind == PointerDeviceKind.touch || kind == PointerDeviceKind.stylus;
  }

  @override
  Widget build(BuildContext context) {
    final content = MergeSemantics(
      child: Semantics(
        label: widget.fromUser ? '你说' : '栖语说',
        child: widget.fromUser
            ? Text(
                widget.text,
                style: QiyuTypography.body.copyWith(color: QiyuColors.ink),
              )
            : QiyuMarkdown(text: widget.text),
      ),
    );

    // 触屏/手写笔指针没有 hover，时刻不能等悬停：以弱透明度常驻。鼠标
    // 指针默认隐藏，悬停才渲染——不渲染而非透明度 0：语义树里也不出现，
    // 页面保持干净。触屏常驻还有一道轻点确认（[_touchRevealed]）：纯
    // 触屏平台档默认常驻，桌面平台（二合一设备）要轻点确认，滑动滚动
    // 列表不再误判。
    final persistent = _touchPointer;
    final atLabel = widget.at == null ? null : formatMessageMoment(widget.at!);
    // at 非空时 Dart 流分析已知 label 非空，无需再断言。
    final revealed = persistent
        ? (_platformDefaultIsTouch || _touchRevealed)
        : _hovering;
    final Widget? atLine = atLabel == null || !revealed
        ? null
        : _atLine(atLabel, persistent);

    final extras = <Widget>[
      if (widget.isSpeaking) ...[
        const SizedBox(height: 6),
        // 正在读：动效位交给「正在读」文本，此时不叠重听键。
        const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(QiyuIcons.volume_up, size: 16),
            SizedBox(width: 4),
            Text('正在读', style: TextStyle(fontSize: 12)),
          ],
        ),
      ] else if (widget.onReplay != null) ...[
        const SizedBox(height: 6),
        _ReplayButton(
          key: Key('chat-replay-${widget.deliveryIndex}'),
          onReplay: widget.onReplay!,
        ),
      ],
    ];
    final body = extras.isEmpty
        ? content
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [content, ...extras],
          );

    Widget message;
    if (!widget.fromUser) {
      // 栖语的话：完全没有气泡，靠左，行高 1.9 由 QiyuMarkdown 的字阶给出。
      message = Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: QiyuLayout.messageMaxWidth,
          ),
          child: body,
        ),
      );
    } else {
      // 用户消息：右对齐水滴气泡，靠面色与背景拉开层次，平时不给描边。
      message = Align(
        alignment: Alignment.centerRight,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: QiyuSpacing.md,
            vertical: QiyuSpacing.sm,
          ),
          constraints: const BoxConstraints(
            maxWidth: QiyuLayout.messageMaxWidth,
          ),
          decoration: BoxDecoration(
            color: QiyuColors.bubbleUser,
            borderRadius: QiyuRadii.bubbleBorder,
            // 高对比模式下面色不再可靠，才补一条可见边（ticket 24）。
            border: Border.fromBorderSide(highContrastSide(context)),
          ),
          child: body,
        ),
      );
    }

    // 时刻行是消息块的**外部一行**：与气泡/文本块之间只隔一条小间隙，
    // 气泡本体尺寸与形态不随它显隐变化（旧实现曾把它放进气泡 extras，
    // 出现即把气泡撑宽撑高）。用户消息的时刻行右对齐贴气泡尾部，栖语
    // 维持左对齐。原先由气泡 margin / 文本块 padding 承担的消息间距
    // 统一挪到块外，时刻行落位后与下一条消息的距离不变。
    final Widget messageBlock = Padding(
      padding: const EdgeInsets.only(bottom: QiyuSpacing.sm),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: widget.fromUser
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          message,
          if (atLine != null) ...[const SizedBox(height: 2), atLine],
        ],
      ),
    );

    if (atLabel == null) {
      return messageBlock;
    }
    // Listener 记录最近一次落在消息上的指针类型（触屏/鼠标形态随事件
    // 切换），MouseRegion 管桌面悬停显隐并包住「气泡 + 时刻行」整体，
    // 鼠标在两者之间移动不触发进出场抖动；GestureDetector 管触屏轻点
    // 显现——tap 要过手势竞技场，滑动滚动列表（拖拽胜出）不再触发，
    // 轻点命中只落在消息本体与时刻行上（deferToChild，按下也不再直接
    // 显现）。不为消息加键盘焦点路径——消息没有键盘操作动作。
    return Listener(
      onPointerDown: _rememberPointerKind,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        onHover: _rememberPointerKind,
        child: GestureDetector(onTap: _handleTapped, child: messageBlock),
      ),
    );
  }

  /// 时刻行：次要档弱色文字（design-system §3 字阶表把时间戳归次要
  /// 档，不落极小档），渲染在气泡/文本块下方外部一行。触屏常驻位再压
  /// 到约两成透明度，弱到不干扰阅读，但要看随时在。
  Widget _atLine(String label, bool persistent) {
    final line = Text(
      label,
      style: QiyuTypography.secondary.copyWith(color: QiyuColors.muted),
    );
    return persistent ? Opacity(opacity: 0.2, child: line) : line;
  }
}

/// 气泡尾部的重听小喇叭：动作名必须显式带进语义树。
///
/// 这里不取「tooltip 即无障碍名」的说法——`test/accessibility_test.dart` 里的
/// 探针用例实测：IconButton 只把 tooltip 写进语义节点的 **tooltip 属性**，
/// label 仍是空的，`find.bySemanticsLabel` 读不到，而触屏没有 hover。
/// 画法与记忆中心的常驻按钮一致：同一份文案既作 tooltip，也作图标语义标签，
/// 再由 [MergeSemantics] 汇成按钮自己的那一个语义节点。
class _ReplayButton extends StatelessWidget {
  const _ReplayButton({super.key, required this.onReplay});

  /// 动作名：tooltip 与无障碍标签共用一份，不许两头各写一遍再漂移。
  static const _actionLabel = '再听一遍这句';

  final VoidCallback onReplay;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: IconButton(
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        tooltip: _actionLabel,
        onPressed: onReplay,
        icon: const Icon(
          QiyuIcons.volume_up,
          size: 16,
          semanticLabel: _actionLabel,
        ),
      ),
    );
  }
}
