// 字体资产内容校验：发布门禁用。解析 App 实际打包的子集字体，断言：
// 1) 文件可解析、是合法 sfnt 容器（魔数、表目录、cmap、glyf/CFF 轮廓表齐全，
//    表不越界）；2) 关键码位在 cmap 中有非 .notdef（gid≠0）的映射。
// 坏字体在门禁红，而不是运行时豆腐块。
//
// 纯 Dart 手工解析最小容器头与 cmap（format 4 / format 12），不引 Node/npm、
// 不加 pub 依赖。与裁剪工作台 design/visual-assets/ 下的 Node 校验脚本互补：
// 那边做字形轮廓级验收，这边做发布门禁的容器与码位底线。
//
// 关键码位来源：
// - 文本字体：产品名「栖语」、界面高频文案代表字（晚/安/好/在/嗯）、全角
//   标点与基本拉丁代表位、CJK 各连续区块的首末哨兵位；与工作台验收清单
//   （design/visual-assets/verify-font.mjs）同源。
// - 图标字体：从 test/icon_glyph_manifest.dart 的实测清单里挑仍有 Dart
//   常量消费（qiyuIconCodePoints）的稳定代表位——这些码位缺了，界面必然
//   出豆腐块。
//
// 用法：dart run scripts/verify_font_assets.dart（在仓库根执行；被
// verify-release-baseline.ps1 调用）。退出码：0 达标；1 不达标。
import 'dart:io';
import 'dart:typed_data';

class _RequiredGlyph {
  const _RequiredGlyph(this.codePoint, this.label);

  final int codePoint;
  final String label;
}

const _textFontKeyGlyphs = <_RequiredGlyph>[
  _RequiredGlyph(0x6816, '栖'),
  _RequiredGlyph(0x8BED, '语'),
  _RequiredGlyph(0x665A, '晚'),
  _RequiredGlyph(0x5B89, '安'),
  _RequiredGlyph(0x597D, '好'),
  _RequiredGlyph(0x5728, '在'),
  _RequiredGlyph(0x55EF, '嗯'),
  _RequiredGlyph(0x3002, '。'),
  _RequiredGlyph(0x3001, '、'),
  _RequiredGlyph(0xFF0C, '，'),
  _RequiredGlyph(0xFF1A, '：'),
  _RequiredGlyph(0xFF1B, '；'),
  _RequiredGlyph(0xFF1F, '？'),
  _RequiredGlyph(0x300A, '《'),
  _RequiredGlyph(0x300B, '》'),
  _RequiredGlyph(0x2014, '—'),
  _RequiredGlyph(0x2026, '…'),
  _RequiredGlyph(0x201C, '“'),
  _RequiredGlyph(0x201D, '”'),
  _RequiredGlyph(0xFF5E, '～'),
  _RequiredGlyph(0x3000, '全角空格'),
  _RequiredGlyph(0x4E00, '一（CJK 统一区首）'),
  _RequiredGlyph(0x9FFF, '鿿（CJK 统一区末）'),
  _RequiredGlyph(0x3400, '㐀（扩展 A 首）'),
  _RequiredGlyph(0x4DBF, '㒿（扩展 A 末）'),
  _RequiredGlyph(0x0041, 'A'),
  _RequiredGlyph(0x0037, '7'),
  _RequiredGlyph(0x0020, '空格'),
];

const _iconFontKeyGlyphs = <_RequiredGlyph>[
  _RequiredGlyph(0xE029, 'mic'),
  _RequiredGlyph(0xE02B, 'mic_off'),
  _RequiredGlyph(0xE14C, 'close'),
  _RequiredGlyph(0xE5C4, 'arrow_back'),
  _RequiredGlyph(0xE872, 'delete'),
  _RequiredGlyph(0xE171, 'download'),
  _RequiredGlyph(0xE150, 'edit'),
  _RequiredGlyph(0xE88D, 'lock'),
  _RequiredGlyph(0xE88E, 'info'),
  _RequiredGlyph(0xE5D2, 'menu'),
  _RequiredGlyph(0xE5D5, 'refresh'),
  _RequiredGlyph(0xE417, 'visibility'),
  _RequiredGlyph(0xE050, 'volume_up'),
  _RequiredGlyph(0xE04F, 'volume_off'),
  _RequiredGlyph(0xE047, 'stop'),
];

const _fontAssets = <String, List<_RequiredGlyph>>{
  'apps/qiyu_flutter/assets/fonts/NotoSerifSC-QiyuSubset.ttf':
      _textFontKeyGlyphs,
  'apps/qiyu_flutter/assets/fonts/MaterialSymbolsOutlined-QiyuSubset.ttf':
      _iconFontKeyGlyphs,
};

void main() {
  final scriptFile = File(Platform.script.toFilePath());
  final repoRoot = scriptFile.parent.parent.path;
  var failed = false;
  _fontAssets.forEach((relativePath, glyphs) {
    final path = '$repoRoot/$relativePath';
    if (!_verifyFont(path, glyphs)) {
      failed = true;
    }
  });
  exit(failed ? 1 : 0);
}

bool _verifyFont(String path, List<_RequiredGlyph> required) {
  stdout.writeln('== $path');
  try {
    final file = File(path);
    if (!file.existsSync()) {
      stdout.writeln('  不达标：文件不存在');
      return false;
    }
    final bytes = file.readAsBytesSync();
    if (bytes.length < 12) {
      stdout.writeln('  不达标：文件不足 12 字节，无法容纳 sfnt 头');
      return false;
    }
    final data = ByteData.sublistView(bytes);

    final magic = data.getUint32(0, Endian.big);
    const legalMagics = <int, String>{
      0x00010000: 'TrueType',
      0x4F54544F: 'CFF (OTTO)',
      0x74727565: 'TrueType (true)',
    };
    if (!legalMagics.containsKey(magic)) {
      stdout.writeln(
        '  不达标：sfnt 魔数 0x${magic.toRadixString(16)} 不是合法字体容器',
      );
      return false;
    }

    final numTables = data.getUint16(4, Endian.big);
    if (numTables == 0 || numTables > 512) {
      stdout.writeln('  不达标：表数量 $numTables 不合理');
      return false;
    }
    final tables = <String, int>{};
    for (var i = 0; i < numTables; i++) {
      final recordAt = 12 + i * 16;
      final tag = String.fromCharCodes(bytes.sublist(recordAt, recordAt + 4));
      final offset = data.getUint32(recordAt + 8, Endian.big);
      final length = data.getUint32(recordAt + 12, Endian.big);
      if (offset + length > bytes.length) {
        stdout.writeln('  不达标：表 $tag 声明范围越界（offset=$offset length=$length）');
        return false;
      }
      tables[tag] = offset;
    }
    if (!tables.containsKey('cmap')) {
      stdout.writeln('  不达标：缺少 cmap 字符映射表');
      return false;
    }
    if (!tables.containsKey('glyf') && !tables.containsKey('CFF ')) {
      stdout.writeln('  不达标：缺少 glyf/CFF 轮廓表');
      return false;
    }

    final cmapOffset = tables['cmap']!;
    final subtableCount = data.getUint16(cmapOffset + 2, Endian.big);
    final subtables = <int>[];
    for (var i = 0; i < subtableCount; i++) {
      final recordAt = cmapOffset + 4 + i * 8;
      final offset = data.getUint32(recordAt + 4, Endian.big);
      subtables.add(cmapOffset + offset);
    }

    var failed = false;
    for (final glyph in required) {
      final gid = _lookupGlyphId(data, subtables, glyph.codePoint);
      final ok = gid != null && gid != 0;
      stdout.writeln(
        '  U+${glyph.codePoint.toRadixString(16).toUpperCase().padLeft(4, '0')} '
        '${glyph.label} -> ${ok ? 'gid $gid' : '缺失'}',
      );
      if (!ok) {
        failed = true;
      }
    }
    return !failed;
  } catch (error) {
    stdout.writeln('  不达标：解析失败（$error）');
    return false;
  }
}

/// 在全部可解析的 Unicode 子表（format 4 / format 12）里找 [codePoint]
/// 的映射；返回 null 表示任何子表都没有映射。
int? _lookupGlyphId(ByteData data, List<int> subtables, int codePoint) {
  for (final base in subtables) {
    final format = data.getUint16(base, Endian.big);
    final gid = switch (format) {
      4 => _lookupFormat4(data, base, codePoint),
      12 => _lookupFormat12(data, base, codePoint),
      _ => null,
    };
    if (gid != null && gid != 0) {
      return gid;
    }
  }
  return null;
}

int? _lookupFormat4(ByteData data, int base, int codePoint) {
  if (codePoint > 0xFFFF) {
    return null;
  }
  final segCount = data.getUint16(base + 6, Endian.big) ~/ 2;
  for (var i = 0; i < segCount; i++) {
    final endCode = data.getUint16(base + 14 + i * 2, Endian.big);
    if (codePoint > endCode) {
      continue;
    }
    final startCode =
        data.getUint16(base + 16 + segCount * 2 + i * 2, Endian.big);
    if (codePoint < startCode) {
      return null;
    }
    final idDeltaPos = base + 16 + segCount * 4 + i * 2;
    final idRangeOffsetPos = idDeltaPos + segCount * 2;
    final idDelta = data.getInt16(idDeltaPos, Endian.big);
    final idRangeOffset = data.getUint16(idRangeOffsetPos, Endian.big);
    if (idRangeOffset == 0) {
      return (codePoint + idDelta) & 0xFFFF;
    }
    final address = idRangeOffsetPos + idRangeOffset + (codePoint - startCode) * 2;
    final glyph = data.getUint16(address, Endian.big);
    if (glyph == 0) {
      return null;
    }
    return (glyph + idDelta) & 0xFFFF;
  }
  return null;
}

int? _lookupFormat12(ByteData data, int base, int codePoint) {
  final nGroups = data.getUint32(base + 12, Endian.big);
  for (var i = 0; i < nGroups; i++) {
    final groupAt = base + 16 + i * 12;
    final start = data.getUint32(groupAt, Endian.big);
    final end = data.getUint32(groupAt + 4, Endian.big);
    if (codePoint < start) {
      return null;
    }
    if (codePoint <= end) {
      final startGlyphId = data.getUint32(groupAt + 8, Endian.big);
      return startGlyphId + (codePoint - start);
    }
  }
  return null;
}
