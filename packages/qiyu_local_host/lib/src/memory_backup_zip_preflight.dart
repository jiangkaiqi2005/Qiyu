part of 'memory_backup.dart';

/// 只读整数和字节范围；在 archive 创建条目和字符串前限制解析预算。
/// 中央原始字节先限额，调用方再保留解码后的 UTF-8 精确计账，
/// 兼容 archive 对非 UTF-8 字节的回退解码而不放开原始分配上界。
final class _BackupZipPreflight {
  _BackupZipPreflight(Uint8List bytes, this.budget)
    : data = ByteData.sublistView(bytes);

  final ByteData data;
  final MemoryBackupBudget budget;
  var _localExtraBytes = 0;

  int _u16(int offset) => data.getUint16(offset, Endian.little);
  int _u32(int offset) => data.getUint32(offset, Endian.little);
  int _u64(int offset) {
    final value = data.getUint64(offset, Endian.little);
    if (value < 0) throw _notABackup();
    return value;
  }

  void _range(int offset, int size, int limit) {
    if (offset < 0 || size < 0 || offset > limit || size > limit - offset) {
      throw _notABackup();
    }
  }

  void _entryCount(int count) {
    if (count > budget.maxEntries) {
      throw const BackupValidationException(
        'unexpected-content',
        '备份包含的文件数量超出预期，已拒绝。',
      );
    }
  }

  /// 返回已验证的签名记录字节数，供解码后的元数据总账继续计入。
  int validate() {
    final directory = _readDirectory();
    final directoryOffset = directory.offset;
    final directoryEnd = directoryOffset + directory.size;
    var cursor = directoryOffset;
    var count = 0;
    var metadata = 0;
    var signatureBytes = 0;
    final localOffsets = <int>{};
    while (cursor < directoryEnd) {
      _range(cursor, 4, directoryEnd);
      // APPNOTE 4.3.12–13：文件头后可有一个数字签名记录。archive
      // 遇到它便结束文件扫描；这里只验证结构和预算，不验证签名内容。
      if (_u32(cursor) == 0x05054b50) {
        _range(cursor, 6, directoryEnd);
        final recordSize = 6 + _u16(cursor + 4);
        _metadataSize(metadata + recordSize);
        _range(cursor, recordSize, directoryEnd);
        if (recordSize != directoryEnd - cursor) throw _notABackup();
        signatureBytes = recordSize;
        break;
      }
      _entryCount(++count);
      _range(cursor, 46, directoryEnd);
      if (_u32(cursor) != ZipFileHeader.signature) throw _notABackup();
      final nameSize = _u16(cursor + 28);
      final extraSize = _u16(cursor + 30);
      final variableSize = nameSize + extraSize + _u16(cursor + 32);
      metadata += variableSize;
      _metadataSize(metadata);
      _range(cursor + 46, variableSize, directoryEnd);
      final entry = _expandZip64(
        cursor + 46 + nameSize,
        extraSize,
        uncompressed: _u32(cursor + 24),
        compressed: _u32(cursor + 20),
        local: _u32(cursor + 42),
        disk: _u16(cursor + 34),
      );
      if (entry.disk != 0) throw _notABackup();
      if (!localOffsets.add(entry.local)) _mismatch();
      _validateLocal(cursor, directoryOffset, entry);
      cursor += 46 + variableSize;
    }
    if (count != directory.count) throw _notABackup();
    return signatureBytes;
  }

  ({int offset, int size, int count}) _readDirectory() {
    final eocd = _findEocd();
    _range(eocd, 22, data.lengthInBytes);
    _range(eocd + 22, _u16(eocd + 20), data.lengthInBytes);
    var declaredCount = _u16(eocd + 10);
    var countOnDisk = _u16(eocd + 8);
    var disk = _u16(eocd + 4);
    var startDisk = _u16(eocd + 6);
    var directoryOffset = _u32(eocd + 16);
    var directorySize = _u32(eocd + 12);
    var directoryLimit = eocd;
    final locator = eocd - 20;
    // archive 不要求普通 EOCD 先出现 sentinel：存在 locator 就覆盖。
    if (locator >= 0 &&
        _u32(locator) == ZipDirectory.zip64EocdLocatorSignature) {
      final zip64 = _u64(locator + 8);
      _range(zip64, 56, locator);
      if (_u32(zip64) != ZipDirectory.zip64EocdSignature ||
          _u32(locator + 4) != 0 ||
          _u32(locator + 16) != 1) {
        throw _notABackup();
      }
      final recordSize = _u64(zip64 + 4);
      if (recordSize < 44) throw _notABackup();
      _range(zip64 + 12, recordSize, locator);
      disk = _u32(zip64 + 16);
      startDisk = _u32(zip64 + 20);
      countOnDisk = _u64(zip64 + 24);
      declaredCount = _u64(zip64 + 32);
      directorySize = _u64(zip64 + 40);
      directoryOffset = _u64(zip64 + 48);
      directoryLimit = zip64;
    }
    _entryCount(declaredCount);
    if (countOnDisk != declaredCount || disk != 0 || startDisk != 0) {
      throw _notABackup();
    }
    _range(directoryOffset, directorySize, directoryLimit);
    return (offset: directoryOffset, size: directorySize, count: declaredCount);
  }

  Never _mismatch() => throw const BackupValidationException(
    'integrity-mismatch',
    '备份文件与清单不一致，已拒绝。',
  );

  void _validateLocal(
    int central,
    int directoryOffset,
    ({int uncompressed, int compressed, int local, int disk}) entry,
  ) {
    final local = entry.local;
    _range(local, 30, directoryOffset);
    if (_u32(local) != ZipFile.zipSignature) throw _notABackup();
    final nameSize = _u16(central + 28);
    final extraSize = _u16(local + 28);
    _localExtraBytes += extraSize;
    _metadataSize(_localExtraBytes);
    // 本地名称必须与已计账的中央名称逐字节一致，因而无需把同一
    // 名称再扣进中央预算；本地 extra 使用独立同量上限。
    if (_u16(local + 26) != nameSize ||
        _u16(local + 6) != _u16(central + 8) ||
        _u16(local + 8) != _u16(central + 10)) {
      _mismatch();
    }
    _range(local + 30, nameSize + extraSize, directoryOffset);
    for (var index = 0; index < nameSize; index += 1) {
      if (data.getUint8(local + 30 + index) !=
          data.getUint8(central + 46 + index)) {
        _mismatch();
      }
    }
    final localSizes = _expandZip64(
      local + 30 + nameSize,
      extraSize,
      uncompressed: _u32(local + 22),
      compressed: _u32(local + 18),
      local: 0,
      disk: 0,
    );
    final descriptor = (_u16(local + 6) & 8) != 0;
    bool matches(int value, int expected) =>
        value == expected || (descriptor && value == 0);
    if (!matches(localSizes.compressed, entry.compressed) ||
        !matches(localSizes.uncompressed, entry.uncompressed) ||
        !matches(_u32(local + 14), _u32(central + 16))) {
      _mismatch();
    }
    final content = local + 30 + nameSize + extraSize;
    _range(content, entry.compressed, directoryOffset);
    if (descriptor) {
      var trailer = content + entry.compressed;
      _range(trailer, 4, directoryOffset);
      if (_u32(trailer) == 0x08074b50) trailer += 4;
      // archive 4.2.0 消费 32 位 descriptor（有或无签名）。
      _range(trailer, 12, directoryOffset);
      if (_u32(trailer) != _u32(central + 16) ||
          _u32(trailer + 4) != entry.compressed ||
          _u32(trailer + 8) != entry.uncompressed) {
        _mismatch();
      }
    }
  }

  ({int uncompressed, int compressed, int local, int disk}) _expandZip64(
    int offset,
    int size, {
    required int uncompressed,
    required int compressed,
    required int local,
    required int disk,
  }) {
    final end = offset + size;
    while (end - offset >= 4) {
      final id = _u16(offset);
      final fieldSize = _u16(offset + 2);
      offset += 4;
      _range(offset, fieldSize, end);
      if (id == 1) {
        var cursor = offset;
        int size64() {
          _range(cursor, 8, offset + fieldSize);
          final value = _u64(cursor);
          cursor += 8;
          return value;
        }

        if (uncompressed == 0xffffffff) uncompressed = size64();
        if (compressed == 0xffffffff) compressed = size64();
        if (local == 0xffffffff) local = size64();
        if (disk == 0xffff) {
          _range(cursor, 4, offset + fieldSize);
          disk = _u32(cursor);
        }
      }
      offset += fieldSize;
    }
    // 与 archive 一致忽略不足 4 字节的未知尾部；必需 ZIP64 字段不能缺。
    if (uncompressed == 0xffffffff ||
        compressed == 0xffffffff ||
        local == 0xffffffff ||
        disk == 0xffff) {
      throw _notABackup();
    }
    return (
      uncompressed: uncompressed,
      compressed: compressed,
      local: local,
      disk: disk,
    );
  }

  void _metadataSize(int size) {
    if (size > budget.maxMetadataBytes) {
      throw const BackupValidationException(
        'unexpected-content',
        '备份目录信息超出预期，已拒绝。',
      );
    }
  }

  int _findEocd() {
    // 与 archive 4.2.0 ZipDirectory._findSignature 的块宽及搜索顺序一致，
    // 包括跨块签名的跳过语义。不能选中一个库随后不会消费的目录。
    final length = data.lengthInBytes - 4;
    if (length <= 0) return -1;
    final chunkSize = length < 1024 ? length : 1024;
    var start = length - chunkSize;
    while (start >= 0) {
      for (var cursor = chunkSize - 4; cursor >= 0; cursor -= 1) {
        if (_u32(start + cursor) == ZipDirectory.eocdSignature) {
          return start + cursor;
        }
      }
      start = start > 0 && start < chunkSize ? 0 : start - chunkSize;
    }
    return -1;
  }
}
