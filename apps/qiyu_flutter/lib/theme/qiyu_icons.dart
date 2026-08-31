// 常量名一律用字体的 glyph name 原文（下划线式），和 Flutter 自己的 `Icons`、
// 以及 test/icon_glyph_manifest.dart 的键一一对应；改成 lowerCamelCase 就会让
// 「码位表 ↔ 字形名」这条对账链多一层翻译。Flutter 仓库对 icons.dart 也是同样处理。
// ignore_for_file: constant_identifier_names
import 'package:flutter/widgets.dart';

import 'qiyu_tokens.dart';

/// 全站图标码位（design-system §4）。
///
/// 字族是 **Material Symbols Outlined 的 ExtraLight（wght 200）静态子集**，
/// 不是 Flutter 内置的 `Icons.*`：内置图标是定宽字形，[Icon] 也没有
/// `strokeWidth` 入口，§4 要的 1.2 细描边在那条路上做不到（用户裁定：引入
/// Material Symbols Outlined 的 ExtraLight（wght 200）**静态实例**，一次性裁出
/// 本项目用到的字形子集。取静态实例而不是可变字体是 §4 的定案：静态实例把字重
/// 烘进轮廓，不需要运行时字轴支持，入库这份字体里也就没有 `fvar` 表。实测描边
/// `40/960 em` ≈ 1.00px @24px，当时是用 `remove` 那个字形量的——该图形本轮没有
/// 界面消费、已从下面的常量表删掉，字形仍留在字体里，实测值不受影响）。
///
/// 常量表只收**有消费方**的图形：零消费的码位删在这里，未裁剪的图形字形留在
/// `assets/fonts/MaterialSymbolsOutlined-QiyuSubset.ttf` 里（`test/`
/// `icon_glyph_manifest.dart` 记的是字体实测清单，比本表多是预期，见该文件）。
///
/// 三条纪律：
/// 1. **只用 outlined 字形**，不混用其他图标库；`_rounded` / `_outlined` /
///    `_none` 这类变体在 Material Symbols 里都归到同一个 outlined 图形。
/// 2. 形状一律沿用 Material 既有图形，不借换字族之机换图形或改语义。
/// 3. 码位必须出自实际入库的那份子集字体（`assets/fonts/`
///    `MaterialSymbolsOutlined-QiyuSubset.ttf`）。生成依据是
///    `test/icon_glyph_manifest.dart`（glyph name → codepoint 清单），
///    两边不一致时 `test/qiyu_theme_test.dart` 的图标资产断言会红。
///
/// 尺寸走 [QiyuIconSpec]（默认 24px，发送钮内的上箭头收一档）。
abstract final class QiyuIcons {
  // ---- 导航三件套（§4 定案：沙漏 / 翻开的书 / 圆形旋钮滑杆）----------------
  /// 历史：沙漏，时间在流。桌面侧边栏与窄屏抽屉的第一项导航。
  static const IconData hourglass_empty = IconData(
    0xE88B,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 记忆中心：翻开的书，两页弧线。导航第二项，记忆区顶部的入口也用它。
  static const IconData menu_book = IconData(
    0xEA19,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 设置：圆形旋钮滑杆。导航第三项。
  static const IconData tune = IconData(
    0xE429,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 窄屏抽屉的三条杠：打开时换成 [close] 收回。
  static const IconData menu = IconData(
    0xE5D2,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 二级页返回（历史详情、诊断、隐私、页头返回键）、抽屉收回与桌面侧边栏
  /// 「回合一页」入口。
  static const IconData arrow_back = IconData(
    0xE5C4,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 抽屉打开时的三条杠收回态、以及各类「关掉这一块」（朗读失败提示、
  /// 备份面板关闭）。
  static const IconData close = IconData(
    0xE14C,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  // ---- composer 与语音输入 / 播报 -----------------------------------------
  /// 发送：上箭头，玻璃紫圆钮里的图形（收一档到 [QiyuIconSpec.sendGlyph]）。
  static const IconData arrow_upward = IconData(
    0xE5D8,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 停止生成（发送钮在流式期间的形态）与停止朗读。
  static const IconData stop = IconData(
    0xE047,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 录音中：带圈停止，点它「说完，转成文字」。
  static const IconData stop_circle = IconData(
    0xEF71,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 麦克风：空闲可录、以及转写失败后重试录音（旧 `mic_rounded` / `mic_none`
  /// 在 outlined 里是同一个图形）。
  static const IconData mic = IconData(
    0xE029,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 麦克风不可用（浏览器不支持或未配置 STT）时的灰态按钮。
  static const IconData mic_off = IconData(
    0xE02B,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 转写进行中的声波标识。
  static const IconData graphic_eq = IconData(
    0xE1B8,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 正在朗读 / 可朗读的喇叭。
  static const IconData volume_up = IconData(
    0xE050,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 音量低档（朗读音量滑杆拖到小值时的图标反馈）。
  static const IconData volume_down = IconData(
    0xE04D,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 静音：该会话已关掉她的声音。
  static const IconData volume_off = IconData(
    0xE04F,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  // ---- 记忆四区（§4 定案：时钟 / 山形 / 单人 / 双人）----------------------
  /// 最近发生：时钟。
  static const IconData schedule = IconData(
    0xE192,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 长期印象：山形。
  static const IconData landscape = IconData(
    0xE3F7,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 关于你：单人。
  static const IconData person = IconData(
    0xE7FD,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 我们的关系：双人。
  static const IconData groups = IconData(
    0xF233,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  // ---- 记忆操作（§4 定案：铅笔 / 雪花 / 禁止圈 / 垃圾桶 / 眼睛）-----------
  /// 修正记忆：铅笔。
  static const IconData edit = IconData(
    0xE150,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 冻结：雪花（她不再引用这条记忆，但内容留着）。
  static const IconData ac_unit = IconData(
    0xEB3B,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 禁提：禁止圈（连冻结都不如，直接不许再提）。
  static const IconData block = IconData(
    0xE033,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 删除：垃圾桶（删除会话、清除产品数据、删掉一条记忆）。
  static const IconData delete = IconData(
    0xE872,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 临时查看：眼睛（看一眼被冻结/禁提的内容，不解除状态）。
  static const IconData visibility = IconData(
    0xE417,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  // ---- 历史、备份与设置动作 ------------------------------------------------
  /// 刷新 / 重试：历史列表重载、诊断重跑、记忆重新整理。
  static const IconData refresh = IconData(
    0xE5D5,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 归档：会话归档与备份入口（§8 的「整理记忆」区块同一图形）。
  static const IconData archive = IconData(
    0xE149,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 导出备份文件到本机。
  static const IconData download = IconData(
    0xE171,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 从本机导入备份文件。
  static const IconData upload_file = IconData(
    0xE9FC,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 保存：把 Provider 配置与 Key 写进本机（送按钮、TTS/STT 区块的保存）。
  static const IconData lock = IconData(
    0xE88D,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 测试连接：闪电。
  static const IconData bolt = IconData(
    0xEA0B,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  // ---- 安全边界与状态反馈 --------------------------------------------------
  /// 隐私与安全的盾：设置里的「隐私」区块。
  static const IconData shield = IconData(
    0xE75B,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 隐私提示：盾里带勾，说明「数据只留在本机」。
  static const IconData privacy_tip = IconData(
    0xF0DC,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 本机健康与安全边界（记忆整理的安全规则区块）。
  static const IconData health_and_safety = IconData(
    0xE1D5,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 运行诊断：心跳监护线，本机 Host 状态块。
  static const IconData monitor_heart = IconData(
    0xEAA2,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 成功：带圈勾（连接测试通过、写入完成）。
  static const IconData check_circle = IconData(
    0xE86C,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 一般说明与中性提示。
  static const IconData info = IconData(
    0xE88E,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  /// 出错：带圈叹号（转写失败、连接失败）。
  static const IconData error = IconData(
    0xE000,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );

  // ---- 框架控件的图标替换 --------------------------------------------------
  /// 下拉框箭头：[DropdownButton] 的 `icon` 可以整只替换且不丢配色与尺寸继承，
  /// 所以设置页的下拉箭头用的是它（否则这一处仍是内置定宽字形）。
  ///
  /// 同一个问题的另一面：[ExpansionTile] 只允许整体替换 `trailing`，换掉就拿不到
  /// 框架自带的旋转动画，所以现网的展开箭头仍是 SDK 自带字形——这是 design-system
  /// §4 记明的例外，不打算补一个 [QiyuIcons] 常量去顶它。
  ///
  /// 播放 / 暂停 / 加号 / 减号 / 勾 / 向下折角 / 放大镜这些图形本轮没有界面消费，
  /// 原先以「派生状态备用」为名常驻常量表；零消费即删，字形仍留在入库字体里
  /// （见文件头与 `test/icon_glyph_manifest.dart`）。要用时按清单里的码位取回来。
  static const IconData arrow_drop_down = IconData(
    0xE5C5,
    fontFamily: QiyuIconSpec.fontFamily,
    fontPackage: null,
  );
}
