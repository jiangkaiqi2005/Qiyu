import 'dart:io';

import 'package:qiyu_windows_host/src/single_instance.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;
  late String runtimePath;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-single-instance-test-',
    );
    runtimePath =
        '${temporaryDirectory.path}${Platform.pathSeparator}runtime';
  });

  tearDown(() async {
    if (temporaryDirectory.existsSync()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  File descriptorFile() => File(
    '$runtimePath${Platform.pathSeparator}instance.json',
  );

  test('primary lease publishes a readable descriptor', () async {
    final lease = SingleInstanceLease.tryAcquire(runtimePath);
    addTearDown(lease.close);

    expect(lease.isPrimary, isTrue);
    lease.writeDescriptor(
      origin: Uri.parse('http://127.0.0.1:41000'),
      activationToken: 'activation-token',
    );

    final descriptor = await lease.readDescriptor();
    expect(descriptor.origin, Uri.parse('http://127.0.0.1:41000'));
    expect(descriptor.activationToken, 'activation-token');
  });

  test('a lease acquired while the lock is held cannot write its descriptor', () {
    final primary = SingleInstanceLease.tryAcquire(runtimePath);
    addTearDown(primary.close);
    final secondary = SingleInstanceLease.tryAcquire(runtimePath);

    expect(secondary.isPrimary, isFalse);
    expect(
      () => secondary.writeDescriptor(
        origin: Uri.parse('http://127.0.0.1:41000'),
        activationToken: 'secondary-token',
      ),
      throwsStateError,
    );
  });

  test('the primary rewrites an existing descriptor atomically', () async {
    final lease = SingleInstanceLease.tryAcquire(runtimePath);
    addTearDown(lease.close);

    lease.writeDescriptor(
      origin: Uri.parse('http://127.0.0.1:41000'),
      activationToken: 'first-token',
    );
    lease.writeDescriptor(
      origin: Uri.parse('http://127.0.0.1:41001'),
      activationToken: 'second-token',
    );

    final descriptor = await lease.readDescriptor();
    expect(descriptor.origin, Uri.parse('http://127.0.0.1:41001'));
    expect(descriptor.activationToken, 'second-token');
    // 原子改写不留临时文件。
    expect(
      temporaryDirectory
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.tmp')),
      isEmpty,
    );
  });

  test('closing the lease removes the descriptor and frees the lock', () async {
    final lease = SingleInstanceLease.tryAcquire(runtimePath);
    lease.writeDescriptor(
      origin: Uri.parse('http://127.0.0.1:41000'),
      activationToken: 'activation-token',
    );

    await lease.close();

    expect(descriptorFile().existsSync(), isFalse);
    final next = SingleInstanceLease.tryAcquire(runtimePath);
    addTearDown(next.close);
    expect(next.isPrimary, isTrue);
  });

  test('a missing descriptor times out with a failure', () async {
    final lease = SingleInstanceLease.tryAcquire(runtimePath);
    addTearDown(lease.close);

    await expectLater(
      lease.readDescriptor(timeout: const Duration(milliseconds: 150)),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('did not publish'),
        ),
      ),
    );
  });

  test('a malformed descriptor keeps retrying until the timeout', () async {
    final lease = SingleInstanceLease.tryAcquire(runtimePath);
    addTearDown(lease.close);
    descriptorFile().writeAsStringSync('{"schemaVersion": 2}');

    await expectLater(
      lease.readDescriptor(timeout: const Duration(milliseconds: 150)),
      throwsA(isA<StateError>()),
    );
  });
}
