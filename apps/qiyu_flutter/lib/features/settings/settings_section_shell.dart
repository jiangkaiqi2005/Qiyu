import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../theme/qiyu_icons.dart';
import '../../theme/qiyu_theme.dart';
import '../../theme/qiyu_tokens.dart';
import '../accessibility.dart';
import '../shell/qiyu_fading_notice.dart';
import '../shell/qiyu_widgets.dart';

/// 设置页各分节共享的壳层：分节 id 名单、折叠状态下发、阅读式分节板、
/// 分节头与几枚各领域共用的表单元件与小机制（受控下拉、钥匙字段、
/// 保存/测试按钮组、结果横幅、忙碌图标、忘记 Key 确认框、校验结论播报）。
///
/// 这里只有**页面级的呈现骨架**，不含任何领域的表单状态、校验或保存
/// 编排——那些在各自的领域模块（`provider_settings_section.dart` 等）里。
/// 壳层被七个分节共用，所以它自己不知道任何一节的业务。

/// 设置页分节的 id：折叠状态在本地存储里存的就是这份名单的子集（design-system
/// §8「折叠状态本地持久化（仅 UI 状态）」）。**改名等于改历史数据**——用户上次
/// 收起来的节会凭一个陌生 id 变回默认态，所以这里只增不改不删。
abstract final class SettingsSectionId {
  static const provider = 'provider';
  static const tts = 'tts';
  static const stt = 'stt';
  static const webSearch = 'web_search';
  static const localData = 'local_data';
  static const privacy = 'privacy';
  static const developer = 'developer';

  /// 七节全集：本地存储里出现的陌生 id 靠它做成员校验（认生的 id 不采纳）。
  static const all = <String>{
    provider,
    tts,
    stt,
    webSearch,
    localData,
    privacy,
    developer,
  };

  /// design-system §8 的默认档：展开「模型连接」「本地数据」，其余五节收起。
  /// 它与 [all] 的差集就是默认展开的那两节。
  static const defaultCollapsed = <String>{
    tts,
    stt,
    webSearch,
    privacy,
    developer,
  };
}

/// 获焦安全保护字段同步：在输入框获焦时不覆盖用户正在输入的草稿。
void syncFocusProtectedField(
  TextEditingController controller,
  FocusNode focusNode,
  String newValue,
) {
  if (!focusNode.hasFocus && controller.text != newValue) {
    controller.text = newValue;
  }
}

/// 折叠状态的页内下发：由设置页挂在整列之上，[SettingsSectionPanel] 就地读
/// 「我这一节展开没有」并把点击交回去。
///
/// 走 InheritedWidget 而不是给七个分节 widget 各加两个构造参数：那七个节是各自
/// 持有 controller 与 FocusNode 的 StatefulWidget，参数只是为了把状态搬运一层，
/// 搬运会把真正的表单代码埋掉。
class SettingsSectionCollapseScope extends InheritedWidget {
  const SettingsSectionCollapseScope({
    super.key,
    required this.collapsed,
    required this.onToggle,
    required super.child,
  });

  /// 当前收起的节 id 集合。
  final Set<String> collapsed;

  /// 分节头被点（或键盘 Enter/Space 激活）时回调。
  final void Function(String sectionId) onToggle;

  bool isExpanded(String sectionId) => !collapsed.contains(sectionId);

  static SettingsSectionCollapseScope of(BuildContext context) {
    // 必须是**登记依赖**的这一种读法：七个分节在 [ListView] 里是 `const` 子节点，
    // 页面 setState 时 `updateChild` 会因为子控件实例没变而整块跳过重建，
    // `getInheritedWidgetOfExactType` 那种「只取值不挂钩」的读法于是永远拿不到新的
    // collapsed——点分节头表面有涟漪、实际一栏都不展开。挂上依赖后由
    // [InheritedElement] 精准通知，且只在 [updateShouldNotify] 为真时重建。
    final scope = context
        .dependOnInheritedWidgetOfExactType<SettingsSectionCollapseScope>();
    assert(scope != null, 'SettingsSectionPanel 必须在设置页之内使用：折叠状态由那一层下发。');
    return scope!;
  }

  @override
  bool updateShouldNotify(SettingsSectionCollapseScope oldWidget) =>
      !setEquals(oldWidget.collapsed, collapsed);
}

/// 设置页的**阅读式分节**（design-system §8 补充约定「设置页用阅读式：分节不用
/// 卡片，小字距次要色标题 + 发丝分隔线」）。卡片形态在决策日志第一轮 #6 被
/// 「六七张卡片堆叠偏重」否掉，选定的是原型变体 B ——
/// `docs/product/prototype/index.html:224-236`，本件的每个数值都按它取。
///
/// 三件事在这一处承担：
/// 1. **分节头**＝可点击的导航（[SettingsSectionHeader]）：13px、w400、
///    [QiyuColors.sectionHeader] 次要字色、3px 字距，尾部指示符；§8「分节标题
///    本身就是导航」，所以不再另做吸顶子导航。
/// 2. **节与节之间**＝1px [QiyuColors.line] 发丝线，**最后一节不画**
///    （原型 `:227` 画线、`:228` `last-of-type` 不画）。
/// 3. **两套留白**＝展开时标题下 8px、节尾 24px 内衬再加 24px 下外边距
///    （原型 `:226`、`:229-230`）；收起时内衬降为 8px、不画线、无下外边距
///    （原型 `:236`）。
///
/// 收起时**只不画内容，本 widget 与分节自身都留在树上**：各节是持有
/// `TextEditingController` / `FocusNode` 的 StatefulWidget，把整节换成占位件
/// 会让用户填了一半的输入框随折叠丢状态。
class SettingsSectionPanel extends StatelessWidget {
  const SettingsSectionPanel({
    super.key,
    required this.sectionId,
    required this.title,
    required this.children,
    this.isLast = false,
  });

  /// 折叠持久化里存的节 id，见 [SettingsSectionId]。
  final String sectionId;

  /// 分节标题：既是本节的名字，也是本节唯一的导航入口。
  final String title;

  /// 展开时才呈现的正文（标题不在这里，由本件统一排版）。
  final List<Widget> children;

  /// 末节（体验与开发者选项）不画下沿发丝线；§8 的分节顺序固定，末节唯一。
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final collapse = SettingsSectionCollapseScope.of(context);
    final expanded = collapse.isExpanded(sectionId);
    final body = Padding(
      padding: EdgeInsets.only(
        // 展开：节尾 `--sp-6` 24px 内衬；收起：内衬降为 `--sp-2` 8px。
        bottom: expanded ? QiyuSpacing.lg : QiyuSpacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsSectionHeader(
            sectionId: sectionId,
            title: title,
            expanded: expanded,
            onToggle: () => collapse.onToggle(sectionId),
          ),
          if (expanded) ...[
            // 标题下 `--sp-2` 8px（原型 `:230` `margin-bottom: var(--sp-2)`）。
            const SizedBox(height: QiyuSpacing.xs),
            // 正文与分节头左缘对齐：分节头外面常驻一圈 3px 的焦点环留白
            // （§9 焦点环 offset，`_QiyuRing` 的 Padding 不因未聚焦而消失），
            // 正文取同一档左缩进，两者左缘才在同一条阅读线上。
            //
            // 这块的键是「展开/收起」唯一的可观察凭据：收起时它整块不在树上，
            // 节内的输入框与按钮也就不在（原型 `:235` `display: none`）。
            Padding(
              key: Key('settings-section-content-$sectionId'),
              padding: const EdgeInsets.only(left: QiyuLayout.focusRingOffset),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children,
              ),
            ),
          ],
        ],
      ),
    );
    return Padding(
      // 整节的定位键：测试据此核「这一节在不在树上」「画没画那条发丝线」，
      // 不必去数内部结构。
      key: Key('settings-section-$sectionId'),
      // 展开时下外边距 24px（原型 `:226` `margin-bottom: var(--sp-6)`）；
      // 收起时归零（原型 `:236` `margin-bottom: 0`）。
      padding: EdgeInsets.only(bottom: expanded ? QiyuSpacing.lg : 0),
      child: expanded && !isLast
          ? DecoratedBox(
              decoration: const BoxDecoration(
                border: Border(bottom: qiyuHairlineSide),
              ),
              child: body,
            )
          : body,
    );
  }
}

/// 分节头：整行可点，是 §8「分节标题本身就是导航」的那一处导航。
///
/// 静置 [QiyuColors.sectionHeader]、悬停转 [QiyuColors.sectionHeaderHover]，
/// 160ms 过渡＝原型 `transition: color 160ms ease`
/// （`docs/product/prototype/index.html:231`）＝ [QiyuMotion.fast]，
/// reduced-motion 下由 [qiyuMotion] 压成零（§9）。
///
/// 焦点表意**不新造机制**：[QiyuOwnFocusRing] 自持节点交给 [InkWell]，环只在
/// 键盘来源时画（§9 的画法与判据都在 [QiyuFocusRing] 那一处），Enter/Space
/// 仍由 InkResponse 激活。
class SettingsSectionHeader extends StatefulWidget {
  const SettingsSectionHeader({
    super.key,
    required this.sectionId,
    required this.title,
    required this.expanded,
    required this.onToggle,
  });

  final String sectionId;
  final String title;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  State<SettingsSectionHeader> createState() => _SettingsSectionHeaderState();
}

class _SettingsSectionHeaderState extends State<SettingsSectionHeader> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 字号走 §3 已登记的次要档（13px），字重与字距按原型变体 B：
    // `font-weight: 400; letter-spacing: 3px`
    // （`docs/product/prototype/index.html:229-230`）。
    final headerStyle = theme.textTheme.bodySmall?.copyWith(
      fontWeight: FontWeight.w400,
      letterSpacing: QiyuType.sectionHeaderLetterSpacing,
    );
    return QiyuOwnFocusRing(
      builder: (context, focusNode) => InkWell(
        key: Key('settings-section-header-${widget.sectionId}'),
        focusNode: focusNode,
        onTap: widget.onToggle,
        onHover: (hovering) => setState(() => _hovered = hovering),
        // **一条**过渡同时带着标题与指示符：原型的 `transition: color 160ms
        // ease` 挂在 `h3` 上
        // （`docs/product/prototype/index.html:231`），而指示符是 `h3::after`
        // 的生成内容（`:233-234`），跟着标题一起变。先前只有标题走
        // `AnimatedDefaultTextStyle`、指示符按 `_hovered` 直接换色，指针一上来
        // 那枚三角是瞬变的。这里按进度把两档前景一起插值，而不是各起一条动画
        // ——两条各自的曲线一旦错开，原型上「整行一起提亮」的观感就散了。
        // 曲线显式给 `Curves.ease`：`TweenAnimationBuilder` 默认是 linear，而 CSS
        // 的 `ease` 就是 `Cubic(0.25, 0.1, 0.25, 1.0)`——SDK 在 `animation/curves.dart`
        // 里对 `Curves.ease` 的自陈就是「same as the CSS easing function `ease`」。
        // 时长一律走 `qiyuMotion()`：§9 要求 reduced-motion 下压成零。
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: _hovered ? 1 : 0),
          duration: qiyuMotion(context, QiyuMotion.fast),
          curve: Curves.ease,
          builder: (context, progress, _) {
            final headerColor = Color.lerp(
              QiyuColors.sectionHeader,
              QiyuColors.sectionHeaderHover,
              progress,
            )!;
            final caretColor = Color.lerp(
              QiyuColors.sectionHeaderCaret,
              QiyuColors.sectionHeaderCaretHover,
              progress,
            )!;
            return Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    // 定位键：本节头里还有一枚同样渲染成 RichText 的指示符，
                    // 测试要读「标题真正落下的那一份」就不能靠子树里的先后次序猜。
                    key: Key('settings-section-title-${widget.sectionId}'),
                    style: headerStyle?.copyWith(color: headerColor),
                  ),
                ),
                // 指示符：原型 `h3::after { content: ' ▾' }` / 收起时 `' ▸'`（
                // `docs/product/prototype/index.html:233-234`）。**不照抄那两个
                // 字符**：U+25BE / U+25B8 不在随包宋体子集覆盖的字区里（决策日志
                // 第四轮 #7 的清单），画出来是豆腐块；`Icons.*` 又被 §4 的细描边
                // 纪律锁死。取已入库的 [QiyuIcons.arrow_drop_down]（实心下三角＝▾
                // 的同形），收起时转 270°（顺时针）成右指（＝▸ 的同形），尺寸与
                // 不透明度仍按原型。
                RotatedBox(
                  quarterTurns: widget.expanded ? 0 : 3,
                  child: Icon(
                    QiyuIcons.arrow_drop_down,
                    size: QiyuType.sectionHeaderCaretSize,
                    color: caretColor,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 按钮图标在忙碌时换成小号进度指示，动作按钮共用同一形态。
Widget settingsBusyOr(bool busy, IconData icon) => busy
    ? const SizedBox.square(
        dimension: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      )
    : Icon(icon);

/// 领域校验结论的页面呈现：渐隐提示播报。带草稿校验的领域（模型连接、
/// 语音朗读、语音输入）都以这一种形态播报校验失败，机制收拢为这一处；
/// 表单持有的 `void Function(String)` 回调由区块闭包绑定 [context] 后
/// 转来，本件只管「怎么说给人听」。
void showSettingsNotice(BuildContext context, String message) {
  showQiyuFadingNotice(context, message);
}

/// 四个凭据领域（模型连接、语音朗读、语音输入、联网搜索）保存成功的
/// 统一轻提示文案：正面陈述存好了，一句到底。四域保存编排各自的调用
/// 点在保存为真时经 [showSettingsNotice] 播报这一句，走同一条渐隐通道。
const String settingsSavedNotice = '已保存到本机。';

/// 四域保存编排的统一收尾：领域区块的 `_save` 在表单保存返回后交出结
/// 果，这里统一判「存上了且页面还在树上」再播报 [settingsSavedNotice]
/// ——挂载检查与播报通道收拢在这一处，未来新增凭据领域不再复制这段
/// 收尾。失败路径不经过这里（错误横幅归各域视图模型），草稿校验失败
/// 仍走各域自己的 [showSettingsNotice] 播报。
mixin SettingsSaveFeedback<T extends StatefulWidget> on State<T> {
  /// 保存结果的统一播报：[saved] 为领域表单 `save()` 的返回值。
  void reportSettingsSaved(bool saved) {
    if (saved && mounted) {
      showSettingsNotice(context, settingsSavedNotice);
    }
  }
}

/// 「忘记已保存 Key」的确认对话框：AlertDialog＋「再想想 / 忘记 Key」
/// 两枚按钮＋`pop(bool)`，四个凭据领域（模型连接、语音朗读、语音输入、
/// 联网搜索）逐字同构，机制收在这里，各领域只带标题与正文文案；取消与
/// 确认的固定字样、确认键的破坏性形态（FilledButton）也一并固定，避免
/// 四处漂移。
///
/// [keyPrefix] 只用于拼测试定位键（`<prefix>forget-key-dialog` 等）；
/// 模型连接域的既有键没有领域前缀，传空串沿用。返回用户是否确认——
/// 取消与摸掉对话框都算未确认；确认后的领域动作（`forgetApiKey`）由
/// 调用方接手，壳层不碰任何一节的视图模型。
Future<bool> confirmSettingsForgetKey({
  required BuildContext context,
  required String keyPrefix,
  required String title,
  required String content,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: Key('${keyPrefix}forget-key-dialog'),
      title: Text(title),
      content: Text(content),
      actions: [
        QiyuFocusRingScope(
          borderRadius: QiyuRadii.circleBorder,
          child: TextButton(
            key: Key('${keyPrefix}forget-key-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('再想想'),
          ),
        ),
        FilledButton(
          key: Key('${keyPrefix}forget-key-confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('忘记 Key'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// 各设置领域共用的受控下拉：外层 [InputDecorator] 撑起与文本框一致的
/// 标签与边框，内层下拉去下划线铺满。

/// 设置页表单输入框的微圆角描边（直边、8px 微圆角，取代过大的胶囊全圆角）。
OutlineInputBorder settingsOutlineBorder({
  Color color = QiyuColors.line,
  double radius = QiyuRadii.small,
}) => OutlineInputBorder(
  borderRadius: BorderRadius.all(Radius.circular(radius)),
  borderSide: BorderSide(width: QiyuLine.hairline, color: color),
);

class SettingsControlledDropdown extends StatelessWidget {
  const SettingsControlledDropdown({
    super.key,
    required this.dropdownKey,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final Key dropdownKey;
  final String label;
  final String value;
  final List<DropdownMenuItem<String>> items;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => InputDecorator(
    decoration: InputDecoration(
      labelText: label,
      border: settingsOutlineBorder(color: QiyuColors.line),
      enabledBorder: settingsOutlineBorder(color: QiyuColors.line),
      focusedBorder: settingsOutlineBorder(color: QiyuColors.composerFocusLine),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        key: dropdownKey,
        value: value,
        isExpanded: true,
        items: items,
        // 下拉箭头是框架内置图标：DropdownButton 的 `icon` 可以整只替换，
        // 颜色和尺寸仍由它自己的 IconTheme 继承，所以图形不变、只换细描边字族。
        icon: const Icon(QiyuIcons.arrow_drop_down),
        onChanged: (next) {
          if (next != null) {
            onChanged(next);
          }
        },
      ),
    ),
  );
}

/// 校验与连通测试的结果行。
///
/// **成功不着色，失败才着色**：§2 的色板里没有任何绿色档（这一处原先写的是
/// 色板外成员 `#91C7A7`），而 §1 的三色纪律把暗红只留给「破坏性操作」与
/// 「故障/失败态」两类——成功不在两类之内，于是它根本没有可用的着色语义，
/// 一律走主题默认字色，成没成由文案自己说。判据与决策日志第五轮 #12（记忆动作
/// 结果横幅「partial 不着色、失败只换前景」）、#15（`danger` 只占那两类）同源。
class SettingsStatusMessage extends StatelessWidget {
  const SettingsStatusMessage({
    super.key,
    required this.message,
    required this.succeeded,
  });

  final String message;
  final bool succeeded;

  @override
  Widget build(BuildContext context) {
    // null＝不覆盖前景：图标退回 IconTheme、文字退回 DefaultTextStyle，
    // 也就是页面主文字色——不着色是这条的默认档，不是漏了配色。
    final color = succeeded ? null : Theme.of(context).colorScheme.error;
    // 校验与连通测试的结果作为 live region 播报：屏幕阅读器不在输入
    // 框上也能听到成败（ticket 24 错误关联）。
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            succeeded ? QiyuIcons.check_circle : QiyuIcons.info,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: TextStyle(color: color)),
          ),
        ],
      ),
    );
  }
}

/// 凭据领域的钥匙块：keySet 标题行（可带一行说明文字）＋ 密文输入框 ＋
/// 「忘记已保存 Key」按钮。
///
/// 四个凭据领域（模型连接、语音朗读、语音输入、联网搜索）同构，只有文案
/// 与视觉档位不同，全部参数化逐字保形：模型连接域多一行说明文字、标题取
/// `titleMedium`、间距 6/16；其余三域无说明行、`titleSmall`、间距 8/8。
/// 输入框与忘记按钮的定位键由参数透传，收拢不动测试定位；密文四属性
/// （obscureText / enableSuggestions:false / autocorrect:false /
/// OutlineInputBorder）固定在这里，新增凭据领域不再照抄。
///
/// 忘记的确认对话框与确认后的领域动作仍归各领域（[confirmSettingsForgetKey]
/// 的调用方闭包），本件只管「画」；保存互斥时调用方传 null 让按钮禁用。
class SettingsApiKeyField extends StatelessWidget {
  const SettingsApiKeyField({
    super.key,
    required this.fieldKey,
    required this.controller,
    required this.focusNode,
    required this.keySet,
    required this.title,
    required this.titleStyle,
    this.description,
    this.descriptionStyle,
    this.gapBelowTitle = 8,
    this.gapAboveField = 8,
    required this.label,
    required this.hint,
    required this.forgetButtonKey,
    required this.forgetLabel,
    required this.onForgetKey,
  }) : assert(
         description == null || descriptionStyle != null,
         '带说明文字就必须给它的样式。',
       );

  /// 输入框的测试定位键。
  final Key fieldKey;
  final TextEditingController controller;
  final FocusNode focusNode;

  /// 是否已保存 Key：决定「忘记已保存 Key」按钮的显隐（标题文案由调用方
  /// 按 [keySet] 拼好传入）。
  final bool keySet;
  final String title;
  final TextStyle? titleStyle;

  /// 标题下的说明文字；只有模型连接域有这一行（如「留空即可继续使用」）。
  final String? description;
  final TextStyle? descriptionStyle;

  /// 标题行与下一行之间、说明行与输入框之间的间距：无说明行的领域用默认
  /// 8/8（后者不生效），模型连接域带说明行取 6/16。
  final double gapBelowTitle;
  final double gapAboveField;

  final String label;
  final String hint;

  /// 忘记按钮的定位键与文案（「忘记已保存的 Key」各域叫法不同）。
  final Key forgetButtonKey;
  final String forgetLabel;

  /// 忘记按钮的回调；null＝按钮禁用（如保存进行中的互斥）。
  final VoidCallback? onForgetKey;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: titleStyle),
        if (description case final descriptionText?) ...[
          SizedBox(height: gapBelowTitle),
          Text(descriptionText, style: descriptionStyle),
          SizedBox(height: gapAboveField),
        ] else
          SizedBox(height: gapBelowTitle),
        TextField(
          key: fieldKey,
          controller: controller,
          focusNode: focusNode,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            border: settingsOutlineBorder(color: QiyuColors.line),
            enabledBorder: settingsOutlineBorder(color: QiyuColors.line),
            focusedBorder: settingsOutlineBorder(
              color: QiyuColors.composerFocusLine,
            ),
          ),
        ),
        if (keySet) ...[
          const SizedBox(height: 8),
          QiyuFocusRingScope(
            borderRadius: QiyuRadii.circleBorder,
            child: TextButton(
              key: forgetButtonKey,
              onPressed: onForgetKey,
              child: Text(forgetLabel),
            ),
          ),
        ],
      ],
    );
  }
}

/// 保存 / 测试连接按钮组：[Wrap]（spacing sm、runSpacing 12）里一枚
/// `FilledButton.icon`（保存，忙碌时图标转小号进度）加一枚可选的
/// `OutlinedButton.icon`（测试连接，同一条忙碌形态）。
///
/// [test] 为 null 即本领域没有测试动作（联网搜索），只渲染保存钮。
/// 测试前的草稿读取与校验编排归调用方闭包（模型连接域「先读草稿再
/// 测试」的顺序留在那里），本件只收按钮形态。
class SettingsSaveTestButtons extends StatelessWidget {
  const SettingsSaveTestButtons({
    super.key,
    required this.saveButtonKey,
    required this.saveLabel,
    required this.saveBusy,
    required this.onSave,
    this.test,
  });

  final Key saveButtonKey;
  final String saveLabel;
  final bool saveBusy;
  final VoidCallback onSave;

  /// 测试按钮的可选档：null＝本领域没有测试动作。
  final ({Key buttonKey, String label, bool busy, VoidCallback onPressed})?
  test;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: QiyuSpacing.sm,
      runSpacing: 12,
      children: [
        FilledButton.icon(
          key: saveButtonKey,
          onPressed: saveBusy ? null : onSave,
          icon: settingsBusyOr(saveBusy, QiyuIcons.lock),
          label: Text(saveLabel),
        ),
        if (test case final testButton?)
          OutlinedButton.icon(
            key: testButton.buttonKey,
            onPressed: testButton.busy ? null : testButton.onPressed,
            icon: settingsBusyOr(testButton.busy, QiyuIcons.bolt),
            label: Text(testButton.label),
          ),
      ],
    );
  }
}

/// 凭据领域按钮组上方的状态消息块：错误横幅＋连接测试结果横幅，任一
/// 出现时在尾部补一段占位间距（把横幅与下面的按钮组隔开）。
///
/// 两条横幅**并列渲染、互不排斥**——这是模型连接与语音输入（以及没有
/// 测试位的联网搜索）的真实形状。合成域（语音朗读）在 errorMessage 非空
/// 时**不**渲染 testResult 横幅：那是 testConnection 播放失败的真实行为
/// 差异（连接已通、试听失败时不留成功横幅），且横幅与占位间距之间还插着
/// 「再听一次试听」恢复入口，本件收不下，该域保持原样不并。
List<Widget> settingsStatusBanners({
  required String? errorMessage,
  ({String message, bool succeeded})? testResult,
  Key? testResultKey,
  required double trailingGap,
}) => [
  if (errorMessage case final message?)
    SettingsStatusMessage(message: message, succeeded: false),
  if (testResult case final result?)
    SettingsStatusMessage(
      key: testResultKey,
      message: result.message,
      succeeded: result.succeeded,
    ),
  if (errorMessage != null || testResult != null)
    SizedBox(height: trailingGap),
];
