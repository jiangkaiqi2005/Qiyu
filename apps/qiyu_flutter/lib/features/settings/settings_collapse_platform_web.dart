import 'package:web/web.dart' as web;

import 'settings_collapse_platform.dart';

/// 浏览器实现：折叠状态存在 `window.localStorage` 的单一键名下，
/// 值是节 id 的逗号串（形如 `tts,web_search`）。
///
/// 与朗读音量（`voice_player_platform_web.dart` 的 `qiyu_voice_output_volume`）
/// 同款先例：**同步读写、异常一律吞掉**（design-system §8「仅 UI 状态，不进主
/// 持久化链路」）。浏览器禁用存储、无痕模式抛错或值被手改坏时，读侧退回
/// 「本机没存过」（null → 页面用 §8 默认档），写侧静默失败——丢的只是一次
/// 展开偏好，不该让设置页报错。
final class LocalStorageSettingsCollapseStore implements SettingsCollapseStore {
  const LocalStorageSettingsCollapseStore();

  @override
  Set<String>? readCollapsed() {
    try {
      // `getItem` 的 null 与空串是两件事：前者＝本机没存过（退回 §8 默认档），
      // 后者＝用户把七节全展开过（必须照原样认）。package:web 的 Storage 没有
      // containsKey，这个区分只能也只需要靠返回类型拿。
      final saved = web.window.localStorage.getItem(
        settingsCollapsedSectionsKey,
      );
      if (saved == null) {
        return null;
      }
      return <String>{
        for (final id in saved.split(','))
          if (id.trim().isNotEmpty) id.trim(),
      };
    } on Object {
      return null;
    }
  }

  @override
  void writeCollapsed(Set<String> collapsed) {
    try {
      web.window.localStorage.setItem(
        settingsCollapsedSectionsKey,
        collapsed.join(','),
      );
    } on Object {
      // 忽略 localStorage 写入异常：折叠状态不是产品数据。
    }
  }
}

SettingsCollapseStore createSettingsCollapseStore() =>
    const LocalStorageSettingsCollapseStore();
