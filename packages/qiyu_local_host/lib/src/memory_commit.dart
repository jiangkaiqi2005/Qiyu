import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'markdown_memory_repository.dart';

/// 同一 Host 的记忆提交边界。维护准入覆盖整项用户操作；commit 只
/// 串行化有限文件的读改写，模型调用、全库扫描和任务排空留在锁外。
/// 锁顺序：episode 日任务 → commit → 树 / loops / controls 内锁。
final class MemoryCommitCoordinator {
  MemoryCommitCoordinator(this.memoryDirectory);

  final String memoryDirectory;
  final Object _commitZone = Object();
  final Object _operationZone = Object();
  Future<void> _tail = Future.value();
  Future<void> _maintenanceTail = Future.value();
  int _revision = 0;
  int _operations = 0;
  int _maintenanceRequests = 0;
  Completer<void>? _reopened;
  Completer<void>? _drained;

  Future<T> commit<T>(Future<T> Function() body) {
    if (_active(_commitZone)) return body();
    final result = _tail.then((_) => _inScope(_commitZone, body));
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<T> operation<T>(Future<T> Function() body) async {
    if (_active(_operationZone)) return body();
    while (_maintenanceRequests > 0) {
      await _reopened!.future;
    }
    _operations += 1;
    try {
      return await _inScope(_operationZone, body);
    } finally {
      _operations -= 1;
      if (_operations == 0) {
        _drained?.complete();
        _drained = null;
      }
    }
  }

  /// 仅供已由聊天串行槽 / 后台排空保护的在途工作和维护内部调用。
  /// 它们的必要写入必须继续完成，不能反过来等待正在排空自己的维护。
  Future<T> existingOperation<T>(Future<T> Function() body) =>
      _inScope(_operationZone, body);

  Future<T> maintenance<T>(Future<T> Function() body) {
    _maintenanceRequests += 1;
    _reopened ??= Completer<void>();
    final result = _maintenanceTail.then((_) async {
      try {
        if (_operations > 0) {
          _drained ??= Completer<void>();
          await _drained!.future;
        }
        return await existingOperation(body);
      } finally {
        _maintenanceRequests -= 1;
        if (_maintenanceRequests == 0) {
          _reopened!.complete();
          _reopened = null;
        }
      }
    });
    _maintenanceTail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  bool _active(Object key) => (Zone.current[key] as _Scope?)?.active ?? false;

  Future<T> _inScope<T>(Object key, Future<T> Function() body) async {
    final scope = _Scope();
    try {
      return await runZoned(body, zoneValues: {key: scope});
    } finally {
      scope.active = false;
    }
  }

  AtomicTextWriter wrap(AtomicTextWriter? writer) =>
      _CommitWriter(this, writer ?? const IoAtomicTextWriter());

  Future<void> delete(File file) => commit(() async {
    if (await file.exists()) {
      await file.delete();
      _changed(file.path);
    }
  });

  void _changed(String target) {
    if (_relevant(target)) _revision += 1;
  }

  bool _relevant(String target) {
    final relative = path.relative(target, from: memoryDirectory);
    final parts = path.split(relative);
    return parts.length == 1 &&
            const {
              longMemoryFileName,
              memoryControlsFileName,
              personaFileName,
              relationshipFileName,
              dailyStateFileName,
              'open-loops.md',
            }.contains(relative) ||
        parts.isNotEmpty &&
            const {'episodes', 'persona-tree'}.contains(parts.first) &&
            target.endsWith('.md');
  }

  /// 实际内容摘要，不使用 mtime / size 缓存。扫描本身不持短锁；扫描
  /// 期间发生产品写入则凭证无效。外部进程不享有跨文件原子协作保证。
  Future<MemoryContentSnapshot> snapshot() async {
    final revision = _revision;
    final hashes = <String, String>{};
    final root = Directory(memoryDirectory);
    if (await root.exists()) {
      for (final name in [
        longMemoryFileName,
        memoryControlsFileName,
        personaFileName,
        relationshipFileName,
        dailyStateFileName,
        'open-loops.md',
      ]) {
        final file = File(path.join(memoryDirectory, name));
        if (await file.exists()) {
          hashes[name] = (await sha256.bind(file.openRead()).first).toString();
        }
      }
      for (final name in ['episodes', 'persona-tree']) {
        final directory = Directory(path.join(memoryDirectory, name));
        if (!await directory.exists()) continue;
        await for (final entity in directory.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File && _relevant(entity.path)) {
            hashes[path.relative(entity.path, from: memoryDirectory)] =
                (await sha256.bind(entity.openRead()).first).toString();
          }
        }
      }
    }
    return MemoryContentSnapshot(revision, hashes, revision == _revision);
  }

  /// 在 commit 内核对锁外刚读到的实际内容与产品写入版本。
  bool unchanged(MemoryContentSnapshot before, MemoryContentSnapshot current) =>
      before.stable &&
      current.stable &&
      before.revision == _revision &&
      current.revision == _revision &&
      before.hashes.length == current.hashes.length &&
      before.hashes.entries.every(
        (entry) => current.hashes[entry.key] == entry.value,
      );
}

final class MemoryContentSnapshot {
  const MemoryContentSnapshot(this.revision, this.hashes, this.stable);
  final int revision;
  final Map<String, String> hashes;
  final bool stable;
}

final class _Scope {
  bool active = true;
}

final class _CommitWriter implements AtomicTextWriter {
  const _CommitWriter(this.coordinator, this.delegate);
  final MemoryCommitCoordinator coordinator;
  final AtomicTextWriter delegate;
  @override
  Future<void> replace(String target, String contents) =>
      coordinator.commit(() async {
        await delegate.replace(target, contents);
        coordinator._changed(target);
      });
}
