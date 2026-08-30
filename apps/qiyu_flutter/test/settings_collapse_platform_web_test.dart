@TestOn('browser')
library;

import 'package:qiyu_flutter/features/settings/settings_collapse_platform.dart'
    hide createSettingsCollapseStore;
import 'package:qiyu_flutter/features/settings/settings_collapse_platform_web.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

/// 折叠状态 web 实现的真实浏览器用例：跑在真 `window.localStorage` 上。
///
/// 这里锁的是决策日志第五轮 #19 的**语义核心**——「本机从没存过」与「存过一个
/// 空集」是两件事。搞混的后果看得见：把七节全部展开过的人下次进来，页面会以为
/// 他没存过，又按 §8 默认档收起五节。widget 测试注入的是内存实现（同目录
/// `_stub.dart`），那条路测不到 localStorage 的 null / 空串之辨，也不该假装测到。
void main() {
  // 这条键在浏览器里跨用例存活：上一条写的值会让下一条读成错的起点。
  setUp(() => _clearStored());
  tearDown(() => _clearStored());

  test('本机从没存过时读出 null，页面据此退回 §8 默认档', () {
    expect(createSettingsCollapseStore().readCollapsed(), isNull);
  });

  test('存过空集读回空集而不是 null：全部展开与没存过是两件事', () {
    final store = createSettingsCollapseStore();
    store.writeCollapsed(<String>{});

    expect(store.readCollapsed(), isEmpty, reason: '空集被折成 null，页面会退回默认档');
    // 落盘的确实是空串——「有存档」这件事在存储层看得见，不靠实现的返回值自证。
    expect(_rawStored(), '');
  });

  test('多节 id 走逗号串往返，且落盘格式与键名一起钉住', () {
    final store = createSettingsCollapseStore();
    store.writeCollapsed(<String>{'tts', 'web_search'});

    expect(store.readCollapsed(), <String>{'tts', 'web_search'});
    expect(_rawStored(), 'tts,web_search');
  });

  test('值被人手改过：重复项与项间空格照样读成集合', () {
    web.window.localStorage.setItem(
      settingsCollapsedSectionsKey,
      'tts, stt ,tts',
    );

    expect(createSettingsCollapseStore().readCollapsed(), <String>{
      'tts',
      'stt',
    });
  });

  test('只认自己那一枚键，别的键上的同类值一概不读', () {
    web.window.localStorage.setItem(
      '${settingsCollapsedSectionsKey}_neighbor',
      'tts',
    );

    expect(
      createSettingsCollapseStore().readCollapsed(),
      isNull,
      reason: '读到了别的键名，说明键名不是单一定位',
    );
  });
}

void _clearStored() =>
    web.window.localStorage.removeItem(settingsCollapsedSectionsKey);

String? _rawStored() =>
    web.window.localStorage.getItem(settingsCollapsedSectionsKey);
