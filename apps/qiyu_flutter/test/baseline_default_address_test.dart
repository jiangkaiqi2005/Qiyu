import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/settings/settings_client.dart';

/// web 缺省地址路径锁定：不注入基址时，网关基座回退同源 `Uri.base`
/// （`HostApiGateway` 的 `_baseUri ?? Uri.base` 缺省），页面全部请求
/// 仍是改造前的同源相对路径——浏览器自动托管 Cookie/Origin/CSRF 的
/// 现状不变。原生壳只通过显式注入 `baseUri` 与会话接管 client 走
/// 另一条路，缺省路径零变化。
void main() {
  test('未注入基址时网关把业务路径解析回 Uri.base 同源地址', () {
    final gateway = HttpSettingsGateway();

    expect(
      gateway.resolve('/api/preferences'),
      Uri.base.resolve('/api/preferences'),
    );
    expect(
      gateway.resolve('/api/bootstrap'),
      Uri.base.resolve('/api/bootstrap'),
    );
  });
}
