import 'settings_collapse_platform.dart';

/// 非 Web 环境（含 widget 测试）的折叠状态实现：只活在**这一个实例**里。
///
/// 内存实现不假装自己会跨进程留下什么：原生构建（当前交付形态里没有）关掉
/// 再开就回到默认档。测试要核「离开设置页再进来还收着」时，注入同一个实例
/// 即可——那正是浏览器侧 localStorage 承担的角色。
final class InMemorySettingsCollapseStore implements SettingsCollapseStore {
  Set<String>? _collapsed;

  @override
  Set<String>? readCollapsed() => _collapsed;

  @override
  void writeCollapsed(Set<String> collapsed) {
    _collapsed = Set<String>.unmodifiable(collapsed);
  }
}

SettingsCollapseStore createSettingsCollapseStore() =>
    InMemorySettingsCollapseStore();
