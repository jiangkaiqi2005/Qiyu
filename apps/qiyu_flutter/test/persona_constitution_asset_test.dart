import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

/// 宪法打版副本守护：`assets/persona/persona-constitution.md` 是仓库
/// 根「栖语人格宪法.md」的入库副本（安卓壳没有文件系统外的原料来
/// 源，宪法随 APK 分发），与仓库根原件、Windows 壳打包复制件三处并
/// 存——无相等性守护则漂移不可接受。本测试逐字节比对仓库根原件与本
/// 包副本，不一致即失败并指出首个差异位置。
void main() {
  const repoFileName = '栖语人格宪法.md';
  const assetRelativePath = 'assets/persona/persona-constitution.md';

  /// 从当前工作目录向上回溯定位仓库根原件：flutter test 的工作目录
  /// 是包根 `apps/qiyu_flutter`（CI 与本机一致），向上回溯对运行目录
  /// 的差异最稳，不依赖相对层数写死。
  File locateRepoConstitution() {
    var directory = Directory.current;
    while (true) {
      final candidate = File(
        '${directory.path}${Platform.pathSeparator}$repoFileName',
      );
      if (candidate.existsSync()) {
        return candidate;
      }
      final parent = directory.parent;
      if (parent.path == directory.path) {
        // 已到文件系统根仍未见：返回占位路径，交给下方 existsSync
        // 断言以 reason 失败，报告回溯起点。
        return File(repoFileName);
      }
      directory = parent;
    }
  }

  /// 首个差异的字节偏移换算成「第几行」（按 LF 计行，与 md 原件一致）。
  int lineAt(List<int> bytes, int offset) =>
      bytes.sublist(0, offset).where((b) => b == 10).length + 1;

  test('安卓宪法资产与仓库根人格宪法逐字节一致', () {
    final repoFile = locateRepoConstitution();
    final assetFile = File(
      '${Directory.current.path}${Platform.pathSeparator}$assetRelativePath',
    );
    expect(
      repoFile.existsSync(),
      isTrue,
      reason: '从 ${Directory.current.path} 向上回溯找不到仓库根 $repoFileName',
    );
    expect(assetFile.existsSync(), isTrue, reason: '宪法资产副本缺失');

    final repoBytes = repoFile.readAsBytesSync();
    final assetBytes = assetFile.readAsBytesSync();
    var firstDiff = -1;
    for (
      var i = 0;
      firstDiff < 0 && i < math.min(repoBytes.length, assetBytes.length);
      i++
    ) {
      if (repoBytes[i] != assetBytes[i]) {
        firstDiff = i;
      }
    }
    if (firstDiff < 0 && repoBytes.length != assetBytes.length) {
      firstDiff = math.min(repoBytes.length, assetBytes.length);
    }
    if (firstDiff < 0) {
      return;
    }
    fail(
      '宪法副本漂移：$assetRelativePath 与仓库根 ${repoFile.path} 不一致，'
      '首个差异在第 $firstDiff 字节（仓库根第 ${lineAt(repoBytes, firstDiff)} 行），'
      '长度 仓库根 ${repoBytes.length} 字节 / 副本 ${assetBytes.length} 字节。'
      '请同步后再交付（Windows 打包件由脚本复制，无需手动处理）。',
    );
  });
}
