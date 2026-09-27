import 'package:qiyu_local_host/qiyu_local_host.dart';

/// 钩子式原子写入器：每次 replace 先按调用序执行测试钩子（用例用它
/// 挂起写回、编排确定性交错），钩子返回后再透传真实写入。只服务配
/// 置事务的交错用例，不参与生产路径。
final class HookedAtomicWriter implements AtomicTextWriter {
  HookedAtomicWriter(this.hook);

  /// [call] 从 1 起按写回顺序编号，[contents] 是本次写回的完整内容。
  final Future<void> Function(int call, String contents) hook;

  var _calls = 0;

  @override
  Future<void> replace(String path, String contents) async {
    await hook(++_calls, contents);
    return const IoAtomicTextWriter().replace(path, contents);
  }
}
