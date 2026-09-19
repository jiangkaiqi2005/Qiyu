import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/qiyu_icons.dart';
import '../../theme/qiyu_theme.dart';
import '../../theme/qiyu_tokens.dart';
import '../accessibility.dart';
import '../time_format.dart';
import 'qiyu_hover_gate.dart';
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
    this.enableCopy = false,
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

  /// 用户气泡的一键复制：true 时用户消息正文之下给一枚复制小钮，点
  /// 一下把本条全文写进剪贴板（只作用于用户消息，栖语的话不给）。
  /// 聊天页开启；历史回看页整页可选中复制，保持默认关闭。
  final bool enableCopy;

  /// 消息时刻（Host 落盘的客观时刻）：消息块下方**外部一行**的次要档
  /// 弱色文字——用户消息右对齐贴气泡尾部，栖语靠左；不参与气泡内布局，
  /// 气泡/文本块本体尺寸不随它显隐变化。鼠标指针默认**完全不渲染**，
  /// 悬停整条消息（含时刻行）才出现；触屏/手写笔指针没有 hover，纯触屏
  /// 平台档以约两成透明度常驻，桌面平台（触屏二合一设备）要轻点消息
  /// 确认——轻点走手势竞技场，滑动滚动列表不算。形态由最近一次落在
  /// 消息上的指针事件驱动——桌面触屏设备（Windows 平板浏览器）不再被
  /// 平台档判成两头落空；尚无指针事件时按 Web 壳层平台档作初始猜测。
  /// null 不占位也不渲染——但生产链路 at 恒非空（用户消息乐观插入即带
  /// 预显时刻，栖语消息交付完成提交即带，Host 落盘恒写），null 只剩
  /// 测试与防御路径。at 非空时时刻位**常驻预留**（见 [_atSlotHeight]）：
  /// 显现只是往槽位里放文字，显隐全程零布局位移。
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

  /// 列表层门控抑制位的本地缓存（滚动与指针行进之或，[QiyuHoverGate.
  /// hoverSuppressedOf]）：[didChangeDependencies] 里随 inherited 值刷新，
  /// `onEnter`/`onHover` 回调与显现延迟的到期复查只读缓存，不在回调里
  /// 做依赖查找。没有列表门控（单气泡用法）时恒为 false——默认不抑制。
  bool _hoverSuppressed = false;

  /// 滚动抑制位单独缓存（[QiyuHoverGate.scrollSuppressedOf]）：只用于
  /// 判定「滚动开始即隐藏已显现的行」的复位时机——行进抑制不复位已
  /// 显现的行，鼠标在同一个大气泡内快速晃动时时刻保持已显是合理的。
  bool _scrollSuppressed = false;

  /// 鼠标指针当前是否停在本块的 MouseRegion 内：由 enter/exit 成对维护。
  /// enter 要在抑制拦截**之前**先记位——滚轮把气泡滑到静止光标下时
  /// onEnter 必被门控拦下，若拦下时什么都不记，抑制解除时就无从知道
  /// 「停稳的光标正停在谁身上」。MouseRegion 的进出场在内容滚动把块
  /// 边界滑过静止光标时同样成对派发，这一位能正确跟踪「指针停稳时光
  /// 标落在哪条消息上」；它不进 build，不需要 setState。
  bool _pointerInside = false;

  /// 显现延迟阀的待触发 Timer：显现路径（`onEnter`/`onHover` 放行）不
  /// 立即落 setState，先过这道短延迟，到期再复查抑制位。
  Timer? _revealTimer;

  /// 显现延迟阀时长。为什么需要这道延迟——同一指针事件里 MouseTracker
  /// 先派发气泡的 `onEnter`、后派发列表层门控的 `onHover`：快速扫入的
  /// 第一颗气泡做判定时，门控还没来得及把该事件记为行进（一事件滞后），
  /// 裸判会闪。80ms 内快速扫过的气泡必然已触发 `onExit`（取消待显现的
  /// Timer），或到期复查时行进抑制已生效（丢弃不显现不重排），两路都
  /// 拦得住；80ms 在「瞬间响应」的感知窗口（约 100ms）内，主动悬停无感。
  static const Duration revealDebounce = Duration(milliseconds: 80);

  /// 时刻位常驻预留槽的总高：2px 显隐间隙 + 19px 时刻行自然行高
  /// （Noto Serif SC 13px，hhea 垂直度量 1.437em ≈ 18.68px，引擎取整
  /// 19）。at 非空时这条槽永远在树里——显现只是把时刻文字放进去，
  /// 文字顶恒为气泡底 + 2px，后续消息零位移；字体或字号若变，此值
  /// 必须与时刻行实际自然行高同步改，否则显现态会把文字挤出槽位或
  /// 留出空当。已知边界：运行时 textScaler 大于 1 会把自然行高按比例
  /// 抬过槽内区、被 RenderParagraph 静默裁切——生产轨道（Flutter Web）
  /// textScaler 恒为 1.0，浏览器缩放走 devicePixelRatio 整体等比，
  /// 登记备查。
  static const double _atSlotHeight = 21;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final suppressed = QiyuHoverGate.hoverSuppressedOf(context);
    final scrollSuppressed = QiyuHoverGate.scrollSuppressedOf(context);
    // 滚动开始（滚动位由假转真）即复位已显现的悬停态并撤掉待显现的
    // 延迟 Timer：「滚动开始即隐藏已显现的行」。依赖变化本身会触发重建
    // （Element.didChangeDependencies 就是 markNeedsBuild），这里直接落
    // 字段即可。行进抑制单独翻转不复位（合并位变化、滚动位没变），见
    // [_scrollSuppressed] 的注释。
    if (scrollSuppressed && !_scrollSuppressed) {
      _hovering = false;
      _cancelReveal();
    }
    // 抑制解除（合并位由真翻假）且指针仍停在本块内：主动调度显现。
    // 这是悬停显现「死区」的修复——指针停稳后 Flutter 不再派发任何
    // 事件，此前显现只由新的 onEnter/onHover 触发，缓冲窗过期后就再无
    // 显现时机；滚轮把气泡滑到光标下、快速移动停稳在气泡上都落这个
    // 死角。走 [_scheduleReveal] 的 80ms 延迟阀，到期照常复查抑制位/
    // mounted/未显现，天然防抖。旧值必须在下方缓存刷新**之前**取。
    final wasSuppressed = _hoverSuppressed;
    _scrollSuppressed = scrollSuppressed;
    _hoverSuppressed = suppressed;
    if (wasSuppressed && !suppressed && _pointerInside && !_hovering) {
      _scheduleReveal();
    }
  }

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

  /// 桌面悬停进入。门控抑制期间不显现：滚轮滚动让消息滑到静止光标下
  /// 时 MouseTracker 会派发 onEnter（缺陷 B），这一步把它挡住。放行也
  /// 不立即显现——经 [revealDebounce] 延迟阀，到期复查抑制位后再落
  /// setState（见常量注释的「一事件滞后」）。onExit 不门控——滚出立即
  /// 隐藏。
  void _handleMouseEnter(PointerEvent event) {
    // 先记位再查抑制：被门控拦下的 enter 同样要把「指针停进了本块」
    // 记下来，抑制解除后的主动显现（[didChangeDependencies]）全靠
    // 这一位，拦下时丢信息正是死区的成因之一。
    _pointerInside = true;
    if (_hoverSuppressed) {
      return;
    }
    _scheduleReveal();
  }

  /// 桌面悬停移动：兜底显现路径。死区修复后，指针已在块内时的抑制解
  /// 除由 [didChangeDependencies] 主动调度显现，从空白处跨进气泡块由
  /// `onEnter` 放行——onHover 显现降为兜底，保留以覆盖时序缝隙并锚定
  /// 既有行为；放行同样经延迟阀。
  void _handleMouseHover(PointerEvent event) {
    _rememberPointerKind(event);
    if (_hoverSuppressed || _hovering) {
      return;
    }
    _scheduleReveal();
  }

  /// 桌面悬停退出：立即隐藏、不门控（语义不变量），同时撤掉待显现的
  /// 延迟 Timer——80ms 内快速扫过的气泡靠这一手拦住（延迟到期前人已
  /// 经走了）。
  void _handleMouseExit(PointerEvent event) {
    _pointerInside = false;
    _cancelReveal();
    setState(() => _hovering = false);
  }

  /// 调度显现：[revealDebounce] 到期时复查抑制位——仍被抑制（行进中/
  /// 滚动中）就丢弃，不显现也不重排；已显现或已卸载同样不动。
  void _scheduleReveal() {
    _revealTimer?.cancel();
    _revealTimer = Timer(revealDebounce, () {
      _revealTimer = null;
      if (!mounted || _hovering) {
        return;
      }
      if (_hoverSuppressed) {
        return;
      }
      setState(() => _hovering = true);
    });
  }

  void _cancelReveal() {
    _revealTimer?.cancel();
    _revealTimer = null;
  }

  @override
  void dispose() {
    _cancelReveal();
    super.dispose();
  }

  /// 复制本条全文：把 [QiyuChatBubble.text] 原样写进剪贴板。即发即忘——
  /// 写剪贴板没有可恢复的失败动作（浏览器拒绝授权时保持安静）。
  void _copyMessageText() {
    unawaited(Clipboard.setData(ClipboardData(text: widget.text)));
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
                style: QiyuTypography.of(
                  context,
                ).body.copyWith(color: QiyuColors.ink),
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
        // 字号随档取极小档（design-system §3 窄屏列），全页面不留大字漏网。
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(QiyuIcons.volume_up, size: 16),
            const SizedBox(width: 4),
            Text(
              '正在读',
              style: TextStyle(fontSize: QiyuTypography.of(context).tinySize),
            ),
          ],
        ),
      ] else if (widget.onReplay != null) ...[
        const SizedBox(height: 6),
        _ReplayButton(
          key: Key('chat-replay-${widget.deliveryIndex}'),
          onReplay: widget.onReplay!,
        ),
      ],
      // 用户消息的一键复制（聊天页）：小钮落在气泡内正文之下。历史回看
      // 页整页可选复制，不走这个入口（enableCopy 默认关）。
      if (widget.fromUser && widget.enableCopy) ...[
        const SizedBox(height: 6),
        _CopyButton(onCopy: _copyMessageText),
      ],
    ];
    final body = extras.isEmpty
        ? content
        : Column(
            // 用户气泡的附加钮贴气泡尾缘（右），栖语的消息保持靠左。
            crossAxisAlignment: widget.fromUser
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [content, ...extras],
          );

    Widget message;
    if (!widget.fromUser) {
      // 栖语的话：完全没有气泡，靠左，行高 1.9 由 QiyuMarkdown 的字阶给出。
      // 左右对齐不在这里做——整块（气泡/文本块 + 时刻行）的对齐由最外层
      // Align 统一管，块内贴尾对齐由 Column.crossAxisAlignment 接管。
      message = ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: QiyuLayout.messageMaxWidth),
        child: body,
      );
    } else {
      // 用户消息：右对齐水滴气泡，靠面色与背景拉开层次，平时不给描边。
      message = Container(
        padding: const EdgeInsets.symmetric(
          horizontal: QiyuSpacing.md,
          vertical: QiyuSpacing.sm,
        ),
        constraints: const BoxConstraints(maxWidth: QiyuLayout.messageMaxWidth),
        decoration: BoxDecoration(
          color: QiyuColors.bubbleUser,
          borderRadius: QiyuRadii.bubbleBorder,
          // 高对比模式下面色不再可靠，才补一条可见边（ticket 24）。
          border: Border.fromBorderSide(highContrastSide(context)),
        ),
        child: body,
      );
    }

    // 时刻行是消息块的**外部一行**：与气泡/文本块之间只隔一条小间隙，
    // 气泡本体尺寸与形态不随它显隐变化（旧实现曾把它放进气泡 extras，
    // 出现即把气泡撑宽撑高）。用户消息的时刻行右对齐贴气泡尾部，栖语
    // 维持左对齐——Column 收缩到最宽子项后由 crossAxisAlignment 贴尾，
    // 不再依赖全宽 Align；块右/左缘贴着哪侧，外层 Align 不动就不动。
    // 原先由气泡 margin / 文本块 padding 承担的消息间距统一挪到块外。
    // at 非空时时刻位**常驻预留**（[_atSlotHeight] 槽位，槽顶 2px 内边距
    // 就是那条显隐间隙）：未显现时槽位空占、时刻行不进树（findsNothing
    // 与语义树语义都不变），显现只是往槽位里放文字，显隐全程零布局
    // 位移；未显现态与下一条消息的距离因此比无时刻语义多 21px（用户
    // 裁定接受——「对话离远了一点也应该显得优雅」）。
    final Widget messageBlock = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: widget.fromUser
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        message,
        if (atLabel != null)
          SizedBox(
            height: _atSlotHeight,
            child: atLine == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: atLine,
                  ),
          ),
      ],
    );

    // 悬停热区收紧（design-system §10 第 10/11 条）：对齐（Align，允许
    // 全宽）与块底消息间距（Padding）都留在 MouseRegion **之外**——旧
    // 结构里全宽 Align 把 MouseRegion 撑成整条横条，同行空白处悬停即
    // 显现时刻，相邻消息的热区还经块底 padding 连成一片。现在
    // MouseRegion 的 bounds 收缩到内容紧致块（Column 收缩到最宽子项 =
    // 气泡宽），同行空白与块底消息间距自动出热区；at 非空时常驻预留的
    // 空槽带（时刻位置，气泡底 +2…+21）则**留在本条热区内**——未显现
    // 时槽位就在 Column 里，悬停时刻位置即显现本条时刻（用户裁定
    // 「时间本来就在那里，鼠标挪到那个地方自动显示」）。
    Widget block = messageBlock;
    if (atLabel != null) {
      // Listener 记录最近一次落在消息上的指针类型（触屏/鼠标形态随事件
      // 切换），MouseRegion 管桌面悬停显隐并包住「气泡 + 时刻行」整体，
      // 鼠标在两者之间移动不触发进出场抖动；进出场回调经列表层行进抑制
      // 门控（[_handleMouseEnter]/[_handleMouseHover]，放行经显现延迟阀；
      // onExit 不门控立即隐藏）。GestureDetector 管触屏轻点显现——tap 要
      // 过手势竞技场，滑动滚动列表（拖拽胜出）不再触发；behavior 显式
      // opaque：块收缩后 RenderParagraph 只在文字处命中，deferToChild 会
      // 漏掉气泡 padding 区域的轻点。不为消息加键盘焦点路径——消息没有
      // 键盘操作动作。
      block = Listener(
        onPointerDown: _rememberPointerKind,
        child: MouseRegion(
          onEnter: _handleMouseEnter,
          onExit: _handleMouseExit,
          onHover: _handleMouseHover,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _handleTapped,
            child: block,
          ),
        ),
      );
    }
    return Align(
      alignment: widget.fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: QiyuSpacing.sm),
        child: block,
      ),
    );
  }

  /// 时刻行：次要档弱色文字（design-system §3 字阶表把时间戳归次要
  /// 档，不落极小档），渲染在气泡/文本块下方外部一行。触屏常驻位再压
  /// 到约两成透明度，弱到不干扰阅读，但要看随时在。
  Widget _atLine(String label, bool persistent) {
    final line = Text(
      label,
      style: QiyuTypography.of(
        context,
      ).secondary.copyWith(color: QiyuColors.muted),
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

/// 用户气泡正文之下的复制小钮：画法与 [_ReplayButton] 逐字同构——
/// tooltip 与图标语义标签共用一份文案（触屏没有 hover，语义树必须有
/// 动作名），[MergeSemantics] 汇成按钮自己的那一个语义节点。
class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.onCopy});

  /// 动作名：tooltip 与无障碍标签共用一份，不许两头各写一遍再漂移。
  static const _actionLabel = '复制这条消息';

  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: IconButton(
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        tooltip: _actionLabel,
        onPressed: onCopy,
        icon: const Icon(
          QiyuIcons.content_copy,
          size: 16,
          semanticLabel: _actionLabel,
        ),
      ),
    );
  }
}
