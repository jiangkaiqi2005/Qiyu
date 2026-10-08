import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'markdown_memory_repository.dart';
import 'memory_commit.dart';
import 'provider_config.dart';

/// episode 向量索引（Episode RAG，Spec「索引格式与工程默认值」）：
/// 本机单一 NDJSON 派生缓存，Markdown episodes 仍是事实来源。首行记录
/// 格式与索引身份（规范化服务地址、模型、输入格式版本、实际维度，不含
/// Key），其后每条记录一行：日期、稳定条目 ID、输入 SHA-256 与 Float32
/// 向量。不缓存私人 query 或原话摘录——摘录不在 embedding 输入里，也不
/// 在索引里。
const episodeRagIndexFormat = 'qiyu-episode-rag-index';

/// 输入格式版本：episode 的 embedding 输入拼装方式改变时递增，旧索引
/// 身份随之失配并显示需重建。
const episodeRagInputFormatVersion = 1;

/// 索引文件在记忆目录内的固定文件名。不入备份导出白名单，也不进本机
/// 快照（memory_backup 两侧同步排除）；「清除产品数据」随记忆目录一并
/// 删除。
const episodeRagIndexFileName = 'recall-vector-index.ndjson';

/// 单条 episode 的 embedding 输入：日期、换行、当前摘要（Spec 表）。
/// 发送前执行秘密脱敏——摘要先过会话脱敏规则再拼装，证据摘录、条目
/// ID、来源引用与本函数的 hash 都不进入 embedding 文本。
String episodeRagEmbeddingInput(String date, String summary) =>
    '$date\n${redactSessionText(summary)}';

/// embedding 输入的 SHA-256（hex）：索引记录它用于发布与查询回读时
/// 核对「当前来源是否还是被向量化的那份摘要」。
String episodeRagInputHash(String input) =>
    sha256.convert(utf8.encode(input)).toString();

/// 索引身份：规范化服务地址、模型、输入格式版本与实际维度。不含 Key
/// ——同作用域仅换 Key 不重算向量（Spec 决策）。空库发布的零条索引
/// 没有实际向量，维度记 0（「无」）；查询侧对零条索引不外发 embedding。
final class EpisodeRagIndexIdentity {
  const EpisodeRagIndexIdentity({
    required this.normalizedBaseUrl,
    required this.model,
    required this.inputFormatVersion,
    required this.dimension,
  });

  factory EpisodeRagIndexIdentity.fromJson(Map<String, Object?> json) {
    final baseUrl = json['baseUrl'];
    final model = json['model'];
    final formatVersion = json['inputFormatVersion'];
    final dimension = json['dimension'];
    if (baseUrl is! String ||
        model is! String ||
        formatVersion is! int ||
        dimension is! int ||
        dimension < 0) {
      throw const FormatException('episode rag identity is invalid');
    }
    return EpisodeRagIndexIdentity(
      normalizedBaseUrl: baseUrl,
      model: model,
      inputFormatVersion: formatVersion,
      dimension: dimension,
    );
  }

  /// 从当前配置推导除维度外的身份各键；维度以实际向量为准，由调用方
  /// 在首批向量合法后补齐。
  static EpisodeRagIndexIdentity identityFor(
    EmbeddingConfig config,
    int dimension,
  ) => EpisodeRagIndexIdentity(
    normalizedBaseUrl: normalizeProviderBaseUri(config.baseUrl).toString(),
    model: config.model.trim(),
    inputFormatVersion: episodeRagInputFormatVersion,
    dimension: dimension,
  );

  final String normalizedBaseUrl;
  final String model;
  final int inputFormatVersion;
  final int dimension;

  Map<String, Object?> toJson() => {
    'baseUrl': normalizedBaseUrl,
    'model': model,
    'inputFormatVersion': inputFormatVersion,
    'dimension': dimension,
  };

  @override
  bool operator ==(Object other) =>
      other is EpisodeRagIndexIdentity &&
      other.normalizedBaseUrl == normalizedBaseUrl &&
      other.model == model &&
      other.inputFormatVersion == inputFormatVersion &&
      other.dimension == dimension;

  @override
  int get hashCode => Object.hash(
    normalizedBaseUrl,
    model,
    inputFormatVersion,
    dimension,
  );
}

/// 索引中的一条向量记录：只含定位所需的最小字段。
final class EpisodeRagIndexEntry {
  const EpisodeRagIndexEntry({
    required this.date,
    required this.entryId,
    required this.inputSha256,
    required this.vector,
  });

  factory EpisodeRagIndexEntry.fromJson(Map<String, Object?> json) {
    final date = json['date'];
    final entryId = json['entryId'];
    final hash = json['inputSha256'];
    final rawVector = json['vector'];
    if (date is! String ||
        entryId is! String ||
        hash is! String ||
        rawVector is! List ||
        rawVector.isEmpty) {
      throw const FormatException('episode rag entry is invalid');
    }
    final vector = Float32List(rawVector.length);
    for (var i = 0; i < rawVector.length; i++) {
      final value = rawVector[i];
      // int 也是 num：兼容把 0 写成整数的序列化；其余类型无效。
      if (value is! num) {
        throw const FormatException('episode rag vector is invalid');
      }
      final component = value.toDouble();
      if (component.isNaN || component.isInfinite) {
        throw const FormatException('episode rag vector is invalid');
      }
      vector[i] = component;
    }
    return EpisodeRagIndexEntry(
      date: date,
      entryId: entryId,
      inputSha256: hash,
      vector: vector,
    );
  }

  final String date;
  final String entryId;

  /// 被向量化时的输入（日期+换行+脱敏摘要）SHA-256：查询回读与发布
  /// 重核都用它判断来源是否仍然匹配。
  final String inputSha256;
  final Float32List vector;

  Map<String, Object?> toJson() => {
    'date': date,
    'entryId': entryId,
    'inputSha256': inputSha256,
    'vector': vector.toList(),
  };
}

/// 已加载的向量索引：身份 + 记录。记录顺序即构建顺序，查询时重排。
final class EpisodeRagIndex {
  const EpisodeRagIndex({required this.identity, required this.entries});

  factory EpisodeRagIndex.fromNdjson(String contents) {
    final lines = const LineSplitter().convert(contents);
    // 空文件与缺首行身份都按损坏处理（缺失与损坏同义：需重建）。
    if (lines.isEmpty) {
      throw const FormatException('episode rag index is empty');
    }
    final header = jsonDecode(lines.first);
    if (header is! Map<String, Object?> ||
        header['format'] != episodeRagIndexFormat ||
        header['formatVersion'] is! int) {
      throw const FormatException('episode rag index header is invalid');
    }
    final identity = EpisodeRagIndexIdentity.fromJson(
      switch (header['identity']) {
        Map<String, Object?> value => value,
        _ => throw const FormatException('episode rag identity is missing'),
      },
    );
    final entries = <EpisodeRagIndexEntry>[];
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) {
        continue;
      }
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('episode rag entry is invalid');
      }
      final entry = EpisodeRagIndexEntry.fromJson(decoded);
      if (entry.vector.length != identity.dimension) {
        throw const FormatException('episode rag dimension mismatch');
      }
      entries.add(entry);
    }
    return EpisodeRagIndex(identity: identity, entries: entries);
  }

  final EpisodeRagIndexIdentity identity;
  final List<EpisodeRagIndexEntry> entries;

  String toNdjson() {
    final buffer = StringBuffer()
      ..writeln(
        jsonEncode({
          'format': episodeRagIndexFormat,
          'formatVersion': episodeRagInputFormatVersion,
          'identity': identity.toJson(),
        }),
      );
    for (final entry in entries) {
      buffer.writeln(jsonEncode(entry.toJson()));
    }
    return buffer.toString();
  }

  /// 精确余弦排名（Spec 表）：最多 [limit] 条，按「分数降序 → 日期升序
  /// → 稳定 ID 升序」确定性排序；同分不靠遍历顺序。按日期与稳定 ID 去
  /// 重（同一条目只保留最高分）。查询向量维度必须与索引身份一致（调用
  /// 方保证），这里只做纯计算。
  List<EpisodeRagIndexEntry> topByCosine(Float32List query, int limit) {
    final queryNorm = _norm(query);
    final ranked = <(double, EpisodeRagIndexEntry)>[];
    for (final entry in entries) {
      final score = _cosine(query, queryNorm, entry.vector);
      ranked.add((score, entry));
    }
    ranked.sort((left, right) {
      final byScore = right.$1.compareTo(left.$1);
      if (byScore != 0) {
        return byScore;
      }
      final byDate = left.$2.date.compareTo(right.$2.date);
      if (byDate != 0) {
        return byDate;
      }
      return left.$2.entryId.compareTo(right.$2.entryId);
    });
    final seen = <String>{};
    final kept = <EpisodeRagIndexEntry>[];
    for (final (_, entry) in ranked) {
      // 日期 + 稳定 ID 去重：排序后同一条目相邻且最高分在前。
      if (!seen.add('${entry.date}|${entry.entryId}')) {
        continue;
      }
      kept.add(entry);
      if (kept.length >= limit) {
        break;
      }
    }
    return kept;
  }
}

double _norm(Float32List vector) {
  var total = 0.0;
  for (final value in vector) {
    total += value * value;
  }
  // 零范数按 1 处理：余弦对零向量本就不可计算，调用侧不会拿零向量
  // 排名（请求侧已拦截），这里只保证不除零。
  return total > 0 ? math.sqrt(total) : 1;
}

double _cosine(Float32List query, double queryNorm, Float32List vector) {
  var dot = 0.0;
  for (var i = 0; i < query.length && i < vector.length; i++) {
    dot += query[i] * vector[i];
  }
  return dot / (queryNorm * _norm(vector));
}

/// 向量索引的读写：临时文件完整写入后原子替换发布（Spec 表「存储」）；
/// 读取失败（缺失、损坏）由调用方按需重建——索引不是事实来源。
///
/// 写入经构造期注入的原子写入器（组合根用 episode 管线的提交协调器
/// wrap，与各存储同律），不自带任何锁：发布只发生在后台构建链上，
/// 天然串行。
final class EpisodeRagIndexStore {
  EpisodeRagIndexStore({
    required this.memoryDirectory,
    required this.commits,
    AtomicTextWriter? atomicWriter,
  }) : _atomicWriter = commits.wrap(atomicWriter);

  final String memoryDirectory;
  final MemoryCommitCoordinator commits;
  final AtomicTextWriter _atomicWriter;

  File get _indexFile => File(
    path.join(memoryDirectory, episodeRagIndexFileName),
  );

  /// 读取已发布的索引；文件缺失或损坏时返回 null（两者同义：需重建）。
  Future<EpisodeRagIndex?> read() async {
    if (!await _indexFile.exists()) {
      return null;
    }
    try {
      return EpisodeRagIndex.fromNdjson(
        await _indexFile.readAsString(encoding: utf8),
      );
    } on Object {
      return null;
    }
  }

  /// 原子发布：NDJSON 整体写入临时文件，成功后原子替换正式文件——
  /// 首次构建失败不发布部分索引，读者要么看到旧索引要么看到完整新索引。
  Future<void> publish(EpisodeRagIndex index) async {
    await atomicReplace(
      _atomicWriter,
      _indexFile.path,
      index.toNdjson(),
      code: 'episode_rag_index_write_failed',
      message: '无法保存记忆召回索引，召回暂不可用。',
    );
  }
}
