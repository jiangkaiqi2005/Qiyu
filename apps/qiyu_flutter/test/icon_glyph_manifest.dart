import 'package:flutter/widgets.dart';
import 'package:qiyu_flutter/theme/qiyu_icons.dart';

// 由 .scratch/icon-subset/build-icon-subset.js 从 MaterialSymbolsOutlined-ExtraLight
// 静态实例的 glyph name 表实测生成，请勿手改：它是发布门禁校验 QiyuIcons 码位
// 与入库子集字体是否一致的凭据（子集里 post 表已不含 glyph name，只能按码位对账）。
//
// T04（2026-10-03）扩裁记录：为 Omni 双工通话补 call / call_end 两个字形，
// 以 fonttools varLib.instancer 从官方可变字体烘出 ExtraLight 静态实例后重裁；
// 既有 46 字形轮廓与旧子集逐字形比对一致（.scratch/icon-subset/ 工作台）。
//
// 两份清单的口径**不同**，别当成一份：
// - [iconGlyphManifest] 是**实际入库字体**的实测记录，字体没重裁就仍是 48 条形。
// - [qiyuIconCodePoints] 是 Dart 常量侧的镜像，只列还有常量的那些（现 41 条）。
// 字体里留着本轮没有界面消费的图形字形是可接受的（play_arrow / pause / add /
// remove / check / expand_more / search 的码位仍在这里，常量却已删），所以重跑
// 裁剪脚本只会刷新上面那份，不会让下面这份自己长回来。两边因此按
// 「常量表 ⊆ 字体清单」单向对账，写在 `test/qiyu_theme_test.dart`。

/// 字形名 -> 实际入库子集字体里的码位，逐条来自子集 cmap 的实测结果。
const Map<String, int> iconGlyphManifest = <String, int>{
  'archive': 0xE149,
  'arrow_back': 0xE5C4,
  'arrow_upward': 0xE5D8,
  'bolt': 0xEA0B,
  'check_circle': 0xE86C,
  'close': 0xE14C,
  'delete': 0xE872,
  'download': 0xE171,
  'edit': 0xE150,
  'error': 0xE000,
  'graphic_eq': 0xE1B8,
  'health_and_safety': 0xE1D5,
  'hourglass_empty': 0xE88B,
  'info': 0xE88E,
  'lock': 0xE88D,
  'menu_book': 0xEA19,
  'menu': 0xE5D2,
  'mic': 0xE029,
  'mic_off': 0xE02B,
  'call': 0xE0B0,
  'call_end': 0xE0B1,
  'monitor_heart': 0xEAA2,
  'privacy_tip': 0xF0DC,
  'refresh': 0xE5D5,
  'shield': 0xE75B,
  'stop_circle': 0xEF71,
  'stop': 0xE047,
  'tune': 0xE429,
  'upload_file': 0xE9FC,
  'volume_down': 0xE04D,
  'volume_off': 0xE04F,
  'volume_up': 0xE050,
  'schedule': 0xE192,
  'landscape': 0xE3F7,
  'person': 0xE7FD,
  'groups': 0xF233,
  'ac_unit': 0xEB3B,
  'block': 0xE033,
  'visibility': 0xE417,
  'content_copy': 0xE14D,
  'play_arrow': 0xE037,
  'pause': 0xE034,
  'add': 0xE145,
  'remove': 0xE15B,
  'check': 0xE5CA,
  'expand_more': 0xE5CF,
  'search': 0xE8B6,
  'arrow_drop_down': 0xE5C5,
};

/// 同一批字形的 Dart 常量入口，用来把上面两个方向对起来。
const Map<String, IconData> qiyuIconCodePoints = <String, IconData>{
  'archive': QiyuIcons.archive,
  'arrow_back': QiyuIcons.arrow_back,
  'arrow_upward': QiyuIcons.arrow_upward,
  'bolt': QiyuIcons.bolt,
  'check_circle': QiyuIcons.check_circle,
  'close': QiyuIcons.close,
  'delete': QiyuIcons.delete,
  'download': QiyuIcons.download,
  'edit': QiyuIcons.edit,
  'error': QiyuIcons.error,
  'graphic_eq': QiyuIcons.graphic_eq,
  'health_and_safety': QiyuIcons.health_and_safety,
  'hourglass_empty': QiyuIcons.hourglass_empty,
  'info': QiyuIcons.info,
  'lock': QiyuIcons.lock,
  'menu_book': QiyuIcons.menu_book,
  'menu': QiyuIcons.menu,
  'mic': QiyuIcons.mic,
  'mic_off': QiyuIcons.mic_off,
  'call': QiyuIcons.call,
  'call_end': QiyuIcons.call_end,
  'monitor_heart': QiyuIcons.monitor_heart,
  'privacy_tip': QiyuIcons.privacy_tip,
  'refresh': QiyuIcons.refresh,
  'shield': QiyuIcons.shield,
  'stop_circle': QiyuIcons.stop_circle,
  'stop': QiyuIcons.stop,
  'tune': QiyuIcons.tune,
  'upload_file': QiyuIcons.upload_file,
  'volume_down': QiyuIcons.volume_down,
  'volume_off': QiyuIcons.volume_off,
  'volume_up': QiyuIcons.volume_up,
  'schedule': QiyuIcons.schedule,
  'landscape': QiyuIcons.landscape,
  'person': QiyuIcons.person,
  'groups': QiyuIcons.groups,
  'ac_unit': QiyuIcons.ac_unit,
  'block': QiyuIcons.block,
  'visibility': QiyuIcons.visibility,
  'content_copy': QiyuIcons.content_copy,
  'arrow_drop_down': QiyuIcons.arrow_drop_down,
};
