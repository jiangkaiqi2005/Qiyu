import 'dart:convert';
import 'dart:io';

final class SingleInstanceLease {
  SingleInstanceLease._({
    required this.runtimeDirectory,
    required this.isPrimary,
    this._lockHandle,
  });

  final Directory runtimeDirectory;
  final bool isPrimary;
  RandomAccessFile? _lockHandle;

  File get _descriptorFile =>
      File('${runtimeDirectory.path}${Platform.pathSeparator}instance.json');

  static SingleInstanceLease tryAcquire(String runtimePath) {
    final runtimeDirectory = Directory(runtimePath)
      ..createSync(recursive: true);
    final lockFile = File(
      '${runtimeDirectory.path}${Platform.pathSeparator}instance.lock',
    );
    final lockHandle = lockFile.openSync(mode: FileMode.append);
    try {
      lockHandle.lockSync(FileLock.exclusive);
      return SingleInstanceLease._(
        runtimeDirectory: runtimeDirectory,
        isPrimary: true,
        lockHandle: lockHandle,
      );
    } on FileSystemException {
      lockHandle.closeSync();
      return SingleInstanceLease._(
        runtimeDirectory: runtimeDirectory,
        isPrimary: false,
      );
    }
  }

  void writeDescriptor({required Uri origin, required String activationToken}) {
    if (!isPrimary || _lockHandle == null) {
      throw StateError('Only the primary instance can write its descriptor');
    }
    final temporaryFile = File('${_descriptorFile.path}.${pid.toString()}.tmp');
    temporaryFile.writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'origin': origin.toString(),
        'activationToken': activationToken,
      }),
      flush: true,
    );
    if (_descriptorFile.existsSync()) {
      _descriptorFile.deleteSync();
    }
    temporaryFile.renameSync(_descriptorFile.path);
  }

  Future<InstanceDescriptor> readDescriptor({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final json =
            jsonDecode(_descriptorFile.readAsStringSync())
                as Map<String, Object?>;
        if (json['schemaVersion'] != 1) {
          throw const FormatException('Unsupported instance descriptor');
        }
        return InstanceDescriptor(
          origin: Uri.parse(json['origin']! as String),
          activationToken: json['activationToken']! as String,
        );
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      } on FormatException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    throw StateError('Existing Qiyu instance did not publish its address');
  }

  Future<void> close() async {
    final handle = _lockHandle;
    _lockHandle = null;
    if (handle == null) {
      return;
    }
    if (_descriptorFile.existsSync()) {
      _descriptorFile.deleteSync();
    }
    handle.unlockSync();
    handle.closeSync();
  }
}

final class InstanceDescriptor {
  const InstanceDescriptor({
    required this.origin,
    required this.activationToken,
  });

  final Uri origin;
  final String activationToken;
}
