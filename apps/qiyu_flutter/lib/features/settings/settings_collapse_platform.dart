export 'settings_collapse_platform_stub.dart'
    if (dart.library.js_interop) 'settings_collapse_platform_web.dart';

/// 设置页分节折叠状态的**本地 UI 状态存储**接缝。
///
/// design-system §8 把这条写得很死：「折叠状态本地持久化（**仅 UI 状态，不进
/// 主持久化链路**）」——它既不经 Host `/api`，也不写本机 Markdown sessions，
/// 与朗读音量用浏览器 localStorage 是同一个先例（Spec 实现决策 15）。因此这里
/// 同步读写、不涉网络、不涉凭据。
///
/// Web 构建走 `window.localStorage`；其余平台与 widget 测试走内存实现
/// （条件导入三文件模式，同 `features/chat/voice_player_platform.dart` 与
/// `features/memory/backup_platform.dart`）。
abstract interface class SettingsCollapseStore {
  /// 读上次收起的节 id 集合。
  ///
  /// 返回 null 表示**本机从未存过**（此时用 §8 的默认档：展开「模型连接」与
  /// 「本地数据」，其余收起）；返回空集表示用户把七节全部展开过，两者语义不同，
  /// 不能都折成空集。读不出来（浏览器禁用存储、值不合法）也返回 null，
  /// 退回默认档而不是抛异常。
  Set<String>? readCollapsed();

  /// 写入当前收起的节 id 集合。同步、失败静默：折叠状态丢了只是下次进来
  /// 退回默认档，不该把设置页弄成一次失败的保存。
  void writeCollapsed(Set<String> collapsed);
}

/// 存储的**唯一键名**：值是节 id 的逗号串（形如 `tts,web_search`）。
///
/// 键名单一是为了不留下第二份可以各自漂移的折叠状态；`test/
/// settings_collapse_platform_web_test.dart` 在真实浏览器里按这个常量读写，
/// 其中一条用例专门断别的键名上的同类值读不进来。
const String settingsCollapsedSectionsKey = 'qiyu_settings_collapsed_sections';

// 工厂 `createSettingsCollapseStore()` 由条件导入的两份实现各自提供，
// 同 `voice_player_platform.dart` / `backup_platform.dart` 的规矩：本文件
// 只声明接缝与键名，不声明无体的顶层函数。
