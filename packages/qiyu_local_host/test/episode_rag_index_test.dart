import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:qiyu_local_host/src/episode_rag_index.dart';
import 'package:qiyu_local_host/src/markdown_memory_repository.dart';
import 'package:qiyu_local_host/src/memory_commit.dart';
import 'package:test/test.dart';

void main() {
  group('episode embedding 输入', () {
    test('输入是日期、换行与脱敏后的摘要', () {
      final input = episodeRagEmbeddingInput('2026-09-01', '用户对芒果过敏');
      expect(input, '2026-09-01\n用户对芒果过敏');
    });

    test('摘要在发送前脱敏：秘密不出仓', () {
      final input = episodeRagEmbeddingInput(
        '2026-09-01',
        '用户的 {"password": "audit-only-secret"} 要收好',
      );
      expect(input.contains('audit-only-secret'), isFalse);
      expect(input.contains('[已脱敏]'), isTrue);
    });

    test('输入 hash 稳定且可复算', () {
      final input = episodeRagEmbeddingInput('2026-09-01', '同一段摘要');
      expect(episodeRagInputHash(input), episodeRagInputHash(input));
      expect(episodeRagInputHash(input).length, 64);
      // 摘要变化 → hash 变化：旧向量据此立即失效。
      final changed = episodeRagEmbeddingInput('2026-09-01', '另一段摘要');
      expect(episodeRagInputHash(input), isNot(episodeRagInputHash(changed)));
    });
  });

  group('向量索引 NDJSON 往返', () {
    test('发布后可完整读回身份与记录', () async {
      final directory = await Directory.systemTemp.createTemp('qiyu-rag-');
      addTearDown(() => directory.delete(recursive: true));
      final store = EpisodeRagIndexStore(
        memoryDirectory: directory.path,
        commits: MemoryCommitCoordinator(directory.path),
        atomicWriter: const IoAtomicTextWriter(),
      );
      const identity = EpisodeRagIndexIdentity(
        normalizedBaseUrl: 'https://api.example.com/v1',
        model: 'text-embedding-test',
        inputFormatVersion: 1,
        dimension: 3,
      );
      final index = EpisodeRagIndex(
        identity: identity,
        entries: [
          EpisodeRagIndexEntry(
            date: '2026-09-01',
            entryId: 's:r:0',
            inputSha256: 'a' * 64,
            vector: Float32List.fromList([1.0, 0.0, 0.0]),
          ),
        ],
      );

      await store.publish(index);
      final loaded = await store.read();

      expect(loaded, isNotNull);
      expect(loaded!.identity, identity);
      expect(loaded.entries, hasLength(1));
      expect(loaded.entries.single.date, '2026-09-01');
      expect(loaded.entries.single.entryId, 's:r:0');
      expect(loaded.entries.single.vector.toList(), [1.0, 0.0, 0.0]);
    });

    test('首行记录格式与身份，不含 Key', () {
      final index = EpisodeRagIndex(
        identity: EpisodeRagIndexIdentity(
          normalizedBaseUrl: 'https://api.example.com/v1',
          model: 'm',
          inputFormatVersion: 1,
          dimension: 2,
        ),
        entries: const [],
      );
      final header = jsonDecode(
        const LineSplitter().convert(index.toNdjson()).first,
      ) as Map<String, Object?>;
      expect(header['format'], episodeRagIndexFormat);
      expect(header['formatVersion'], 1);
      expect((header['identity'] as Map)['model'], 'm');
      expect(index.toNdjson().contains('apiKey'), isFalse);
      expect(index.toNdjson().contains('sk-'), isFalse);
    });

    test('空库可发布为零条就绪索引', () async {
      final directory = await Directory.systemTemp.createTemp('qiyu-rag-');
      addTearDown(() => directory.delete(recursive: true));
      final store = EpisodeRagIndexStore(
        memoryDirectory: directory.path,
        commits: MemoryCommitCoordinator(directory.path),
        atomicWriter: const IoAtomicTextWriter(),
      );
      await store.publish(
        EpisodeRagIndex(
          identity: EpisodeRagIndexIdentity(
            normalizedBaseUrl: 'x',
            model: 'm',
            inputFormatVersion: 1,
            dimension: 2,
          ),
          entries: const [],
        ),
      );
      final loaded = await store.read();
      expect(loaded, isNotNull);
      expect(loaded!.entries, isEmpty);
    });

    test('缺失返回 null（需重建），损坏返回 null 绝不部分读出', () async {
      final directory = await Directory.systemTemp.createTemp('qiyu-rag-');
      addTearDown(() => directory.delete(recursive: true));
      final store = EpisodeRagIndexStore(
        memoryDirectory: directory.path,
        commits: MemoryCommitCoordinator(directory.path),
        atomicWriter: const IoAtomicTextWriter(),
      );
      expect(await store.read(), isNull);

      await File(
        path.join(directory.path, episodeRagIndexFileName),
      ).writeAsString('{not json}\n');
      expect(await store.read(), isNull);
    });

    test('维度不符与非法数值的记录按整体损坏处理', () {
      final header = jsonEncode({
        'format': episodeRagIndexFormat,
        'formatVersion': 1,
        'identity': {
          'baseUrl': 'x',
          'model': 'm',
          'inputFormatVersion': 1,
          'dimension': 2,
        },
      });

      // 单条向量维度与身份不符：整个索引不可读出。
      expect(
        () => EpisodeRagIndex.fromNdjson(
          '$header\n${jsonEncode({
            'date': '2026-09-01',
            'entryId': 'e',
            'inputSha256': 'a' * 64,
            'vector': [1.0, 2.0, 3.0],
          })}',
        ),
        throwsFormatException,
      );

      // 非有限数值：不可进入有效索引。
      expect(
        () => EpisodeRagIndex.fromNdjson(
          '$header\n${jsonEncode({
            'date': '2026-09-01',
            'entryId': 'e',
            'inputSha256': 'a' * 64,
            'vector': [1.0, 0.0],
          }).replaceAll('0.0', 'NaN')}',
        ),
        throwsFormatException,
      );
    });
  });

  group('精确余弦排名', () {
    EpisodeRagIndex index(List<(String, List<double>)> entries) =>
        EpisodeRagIndex(
          identity: EpisodeRagIndexIdentity(
            normalizedBaseUrl: 'x',
            model: 'm',
            inputFormatVersion: 1,
            dimension: 2,
          ),
          entries: [
            for (final (id, vector) in entries)
              EpisodeRagIndexEntry(
                date: id.split('|').first,
                entryId: id.split('|').last,
                inputSha256: 'a' * 64,
                vector: Float32List.fromList(vector),
              ),
          ],
        );

    test('按余弦降序取最多 limit 条', () {
      final idx = index([
        ('2026-09-01|a', [1.0, 0.0]),
        ('2026-09-02|b', [0.9, 0.1]),
        ('2026-09-03|c', [0.0, 1.0]),
      ]);
      final top = idx.topByCosine(Float32List.fromList([1.0, 0.0]), 2);
      expect(top.map((entry) => entry.entryId), ['a', 'b']);
    });

    test('同分确定性排序：日期升序、稳定 ID 升序', () {
      final idx = index([
        ('2026-09-02|b', [1.0, 0.0]),
        ('2026-09-01|b', [1.0, 0.0]),
        ('2026-09-01|a', [1.0, 0.0]),
      ]);
      final top = idx.topByCosine(Float32List.fromList([1.0, 0.0]), 3);
      expect(top.map((entry) => entry.entryId).toList(), ['a', 'b', 'b']);
      expect(top.map((entry) => entry.date).toList(), [
        '2026-09-01',
        '2026-09-01',
        '2026-09-02',
      ]);
    });

    test('身份含规范化地址、模型、输入格式版本与维度，参与相等', () {
      const identity = EpisodeRagIndexIdentity(
        normalizedBaseUrl: 'https://api.example.com/v1',
        model: 'm',
        inputFormatVersion: 1,
        dimension: 3,
      );
      expect(
        identity,
        const EpisodeRagIndexIdentity(
          normalizedBaseUrl: 'https://api.example.com/v1',
          model: 'm',
          inputFormatVersion: 1,
          dimension: 3,
        ),
      );
      // 同维度不同模型：身份不同（旧索引不可用于新模型）。
      expect(
        identity,
        isNot(
          const EpisodeRagIndexIdentity(
            normalizedBaseUrl: 'https://api.example.com/v1',
            model: 'other',
            inputFormatVersion: 1,
            dimension: 3,
          ),
        ),
      );
    });
  });
}
