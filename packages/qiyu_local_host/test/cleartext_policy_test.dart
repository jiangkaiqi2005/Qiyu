import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

void main() {
  group('明文允许列表：chatCleartextRefusalReason', () {
    group('https 一律放行', () {
      for (final url in [
        'https://api.openai.com/v1',
        'https://8.8.8.8/v1',
        'HTTPS://api.anthropic.com/v1',
        'https://192.168.1.10:11434',
      ]) {
        test('放行 $url', () {
          expect(chatCleartextRefusalReason(Uri.parse(url)), isNull);
        });
      }
    });

    group('http 私有网段字面量放行', () {
      for (final url in [
        // 10/8 两端边界与内部
        'http://10.0.0.1:11434',
        'http://10.255.255.255',
        // 172.16/12 边界内侧，边界外侧（172.15/172.32）落在拒绝矩阵
        'http://172.16.0.1',
        'http://172.31.255.255',
        // 192.168/16
        'http://192.168.0.0:11434',
        'http://192.168.255.254:8080',
        // 127/8 全段
        'http://127.0.0.1:11434',
        'http://127.255.255.254',
        // 大小写：scheme 与主机名不区分大小写
        'http://LOCALHOST:11434',
        'HTTP://127.0.0.1:11434',
        'http://LocalHost.LocalHost:11434',
        // IPv6 环回与 IPv4 映射形态
        'http://[::1]:11434',
        'http://[::ffff:127.0.0.1]:11434',
        'http://[::ffff:192.168.1.5]:11434',
        'http://[0:0:0:0:0:0:0:1]:11434',
      ]) {
        test('放行 $url', () {
          expect(chatCleartextRefusalReason(Uri.parse(url)), isNull);
        });
      }
    });

    group('http 公网与无法判定的目标一律拒绝', () {
      // IP 字面量（公网与保留段）：文案点「改用 HTTPS」。
      for (final url in [
        'http://8.8.8.8/v1',
        'http://1.2.3.4:8080',
        // 172.16/12 边界外侧
        'http://172.15.255.255',
        'http://172.32.0.1',
        // 相邻私网段的「像私网」地址
        'http://192.169.0.1',
        'http://11.0.0.1',
        // 非 ticket 允许列表的 IPv6 公网／链路本地／ULA
        'http://[2001:db8::1]:11434',
        'http://[fe80::1]:11434',
        'http://[fd00::1]:11434',
        // 保留段 IP 字面量
        'http://0.0.0.0:11434',
      ]) {
        test('拒绝（公网 IP 文案）$url', () {
          final reason = chatCleartextRefusalReason(Uri.parse(url));
          expect(reason, isNotNull);
          expect(reason, contains('私有网段'));
          expect(reason, contains('HTTPS'));
        });
      }

      // 主机名形态（域名、mDNS／.local 名）：文案点「请直接填 IP」，
      // 不说「公网地址」——它不是公网 IP，误导会赶跑局域网用户。
      for (final url in [
        'http://api.example.com/v1',
        'http://my-home-pc.local:11434',
        // 冒号连串的畸形不是 IP 字面量，按主机名型拒绝
        'http://10.0.0.0.1',
      ]) {
        test('拒绝（主机名文案）$url', () {
          final reason = chatCleartextRefusalReason(Uri.parse(url));
          expect(reason, isNotNull);
          expect(reason, contains('填 IP 地址'));
          expect(reason, isNot(contains('公网')));
        });
      }

      test('拒绝文案不回显目标地址', () {
        for (final url in [
          'http://secret-host.example.com:9999',
          'http://8.8.8.8:9999',
        ]) {
          final reason = chatCleartextRefusalReason(Uri.parse(url));
          expect(reason, isNot(contains('secret-host')));
        }
      });
    });
  });

  group('isPrivateOrLoopbackHost', () {
    for (final host in [
      'localhost',
      'LOCALHOST',
      'a.localhost',
      '10.1.2.3',
      '172.16.0.1',
      '172.31.255.255',
      '192.168.1.1',
      '127.0.0.1',
      '::1',
      '::ffff:10.0.0.1',
    ]) {
      test('true $host', () => expect(isPrivateOrLoopbackHost(host), isTrue));
    }
    for (final host in [
      '',
      'example.com',
      '172.32.0.1',
      '172.15.0.1',
      '192.169.1.1',
      '8.8.8.8',
      '2001:db8::1',
      'fe80::1',
      '::ffff:8.8.8.8',
      '999.1.1.1',
    ]) {
      test('false $host', () => expect(isPrivateOrLoopbackHost(host), isFalse));
    }
  });

  group('ProxyRules.findProxyFor', () {
    const rules = ProxyRules(host: 'proxy.lan', port: 7890);
    test('普通主机不加方括号', () {
      expect(
        rules.findProxyFor(Uri.parse('https://api.openai.com/v1')),
        'PROXY proxy.lan:7890',
      );
    });
    test('IPv6 字面量主机加方括号', () {
      const v6 = ProxyRules(host: '::1', port: 8888);
      expect(
        v6.findProxyFor(Uri.parse('https://api.openai.com/v1')),
        'PROXY [::1]:8888',
      );
    });
    test('配置写成括号形态时不重复加括号', () {
      const bracketed = ProxyRules(host: '[::1]', port: 8888);
      expect(
        bracketed.findProxyFor(Uri.parse('https://api.openai.com/v1')),
        'PROXY [::1]:8888',
      );
    });
  });

  group('代理地址冒号校验（ProxyConfig.validate）', () {
    test('「IP:端口」合写在地址里被拒（端口有独立字段）', () {
      const config = ProxyConfig(enabled: true, host: '1.2.3.4:8080', port: 7890);
      expect(
        () => config.validate(),
        throwsA(
          isA<ProviderConfigException>().having(
            (error) => error.message,
            'message',
            '代理地址请填主机名或 IP，端口单独填。',
          ),
        ),
      );
    });

    test('畸形冒号串被拒（host:port、半个括号）', () {
      for (final host in ['proxy.lan:7890', '[::1', '1.2.3.4:8080:9090']) {
        expect(
          () => ProxyConfig(enabled: true, host: host, port: 7890).validate(),
          throwsA(isA<ProviderConfigException>()),
          reason: host,
        );
      }
    });

    test('裸 IPv6 与括号 IPv6 字面量都放行，主机名照常放行', () {
      expect(
        () => const ProxyConfig(enabled: true, host: '::1', port: 7890)
            .validate(),
        returnsNormally,
      );
      expect(
        () => const ProxyConfig(enabled: true, host: '[::1]', port: 7890)
            .validate(),
        returnsNormally,
      );
      expect(
        () => const ProxyConfig(enabled: true, host: 'proxy.lan', port: 7890)
            .validate(),
        returnsNormally,
      );
    });
  });
}
