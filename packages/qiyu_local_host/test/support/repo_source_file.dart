import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

/// 护栏与契约文件的落点定位（票 10 / ADR 0022）：源文件按包配置解析
/// 到仓内真源，仓库根契约文件从本包根向上定位。从任意目录运行测试
/// 都取到同一份文件，摆脱「dart test 固定在包根目录运行」的目录约定。

/// 按包配置解析路径依赖包内的 lib 源文件，如
/// `package:qiyu_behavior_core/src/hidden_actions.dart` 解析到
/// 仓库内 `packages/qiyu_behavior_core/lib/src/hidden_actions.dart`。
File resolvePackageSource(String packageUri) {
  final resolved = Isolate.resolvePackageUriSync(Uri.parse(packageUri));
  if (resolved == null || !resolved.isScheme('file')) {
    fail('无法按包配置解析 $packageUri：检查路径依赖是否就位');
  }
  final file = File.fromUri(resolved);
  if (!file.existsSync()) {
    fail('$packageUri 解析到 ${file.path}，但文件不存在');
  }
  return file;
}

/// 从本包根逐级向上定位仓库根下的文件（如 contracts 契约 JSON）：
/// 契约文件不在任何包内，以包根为锚向上找首个存在目标文件的祖先目录。
File resolveRepoFile(String relativePath) {
  final packageLibUri = Isolate.resolvePackageUriSync(
    Uri.parse('package:qiyu_local_host/qiyu_local_host.dart'),
  );
  if (packageLibUri == null || !packageLibUri.isScheme('file')) {
    fail('无法按包配置定位本包根，仓库文件 $relativePath 无从定位');
  }
  // <包根>/lib/<入口>.dart 上跳一级得包根，再逐级向上找仓库根。
  var directory = File.fromUri(packageLibUri).parent.parent;
  while (true) {
    final candidate = File('${directory.path}/$relativePath');
    if (candidate.existsSync()) {
      return candidate;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      fail('向上找不到仓库文件 $relativePath：请在仓库工作区内运行测试');
    }
    directory = parent;
  }
}
