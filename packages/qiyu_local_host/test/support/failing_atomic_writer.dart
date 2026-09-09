import 'dart:io';

import 'package:qiyu_local_host/qiyu_local_host.dart';

/// 谓词式失败注入原子写入器：[shouldFail] 命中的路径抛 [exception]，
/// 其余写入透传给真实的 IoAtomicTextWriter。
///
/// 触发条件里需要计数或开关的用例（第 N 次失败、可翻转的拦截）在谓词
/// 闭包里自带可变状态；每个注入点的异常消息逐一对得上原替身。
final class FailingAtomicTextWriter implements AtomicTextWriter {
  FailingAtomicTextWriter({
    required this.shouldFail,
    this.exception = const FileSystemException('mock interrupted write'),
  });

  final bool Function(String path) shouldFail;
  final FileSystemException exception;

  @override
  Future<void> replace(String path, String contents) {
    if (shouldFail(path)) {
      throw exception;
    }
    return const IoAtomicTextWriter().replace(path, contents);
  }
}
