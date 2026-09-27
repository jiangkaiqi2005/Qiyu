import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/baseline/android_secret_store.dart';
import 'package:qiyu_local_host/qiyu_local_host.dart';

/// Android 凭据仓 Dart 侧的验收（平台通道模拟原生回包，测的是我们
/// 自己的通道粘合代码：序列化、三方法语义、错误映射——原生 Keystore
/// 行为归真机冒烟，不在 dart 测试里 mock 平台业务）：
///
/// - set/get/delete 与通道协议三方法一一对应，读写对中文、空格与
///   长值无损；
/// - 通道错误（PlatformException）与「无原生处理器」
///   （MissingPluginException）统一转 [SecretStoreException]，对外
///   文案固定、绝不携带 Key 内容。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(androidSecureStoreChannelName);
  const store = AndroidSecretStore();

  /// 模拟原生的密文条目表（key = scope）。
  late Map<String, String> nativeEntries;
  late List<MethodCall> nativeCalls;

  void installNativeStub({PlatformException? error}) {
    TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call);
      if (error != null) {
        throw error;
      }
      final args = call.arguments! as Map<Object?, Object?>;
      final scope = args['scope']! as String;
      switch (call.method) {
        case 'get':
          return nativeEntries[scope];
        case 'set':
          nativeEntries[scope] = args['value']! as String;
          return null;
        case 'delete':
          nativeEntries.remove(scope);
          return null;
        default:
          throw PlatformException(code: 'unknown_method');
      }
    });
  }

  setUp(() {
    nativeEntries = {};
    nativeCalls = [];
    installNativeStub();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('writeApiKey 后 readApiKey 原样返回', () async {
    const scope = 'openai_compatible|https://example.com';

    await store.writeApiKey(scope, 'sk-qiyu-123');

    expect(await store.readApiKey(scope), 'sk-qiyu-123');
  });

  test('读写往返对中文、空格、制表符与长值无损', () async {
    const scope = 'anthropic|https://example.com';
    final longKey = 'Aa1-${'x' * 5000}';
    final trickyKeys = [
      'sk-带中文的粘贴值',
      ' 首尾空格保留 ',
      'tab\tinside',
      longKey,
    ];

    for (final value in trickyKeys) {
      await store.writeApiKey(scope, value);
      expect(await store.readApiKey(scope), value);
    }
  });

  test('读取缺失条目返回 null', () async {
    expect(await store.readApiKey('openai_compatible|https://missing.com'),
        isNull);
  });

  test('deleteApiKey 后读取为 null，未删除的其他条目不受影响', () async {
    const scopeA = 'openai_compatible|https://a.com';
    const scopeB = 'anthropic|https://b.com';
    await store.writeApiKey(scopeA, 'sk-a');
    await store.writeApiKey(scopeB, 'sk-b');

    await store.deleteApiKey(scopeA);

    expect(await store.readApiKey(scopeA), isNull);
    expect(await store.readApiKey(scopeB), 'sk-b');
  });

  test('三方法与通道协议一一对应，参数按约定形状传递', () async {
    const scope = 'openai_compatible|https://example.com';

    await store.writeApiKey(scope, 'sk-qiyu-123');
    await store.readApiKey(scope);
    await store.deleteApiKey(scope);

    expect(
      [for (final call in nativeCalls) call.method],
      ['set', 'get', 'delete'],
    );
    expect(nativeCalls[0].arguments, {'scope': scope, 'value': 'sk-qiyu-123'});
    expect(nativeCalls[1].arguments, {'scope': scope});
    expect(nativeCalls[2].arguments, {'scope': scope});
  });

  test('通道错误统一转 SecretStoreException，文案固定且不携带 Key 内容',
      () async {
    const scope = 'openai_compatible|https://example.com';
    const secret = 'sk-绝不能出现在异常文案里';
    installNativeStub(
      error: PlatformException(code: 'SECURE_STORE_ERROR'),
    );

    final readError = await _captureError(() => store.readApiKey(scope));
    final writeError = await _captureError(
      () => store.writeApiKey(scope, secret),
    );
    final deleteError = await _captureError(() => store.deleteApiKey(scope));

    expect(readError.toString(), '无法读取本机安全存储中的 API Key。');
    expect(writeError.toString(), '无法安全保存 API Key。');
    expect(deleteError.toString(), '无法删除本机安全存储中的 API Key。');
    for (final error in [readError, writeError, deleteError]) {
      expect(error.cause, isA<PlatformException>());
      expect(error.toString(), isNot(contains(secret)));
    }
  });

  test('无原生处理器（MissingPluginException）同样转 SecretStoreException',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);

    final error = await _captureError(
      () => store.readApiKey('openai_compatible|https://example.com'),
    );

    expect(error.toString(), '本机安全存储在此环境不可用。');
    expect(error.cause, isA<MissingPluginException>());
  });
}

Future<SecretStoreException> _captureError(
  Future<Object?> Function() action,
) async {
  try {
    await action();
  } on SecretStoreException catch (error) {
    return error;
  }
  fail('应当抛出 SecretStoreException。');
}
