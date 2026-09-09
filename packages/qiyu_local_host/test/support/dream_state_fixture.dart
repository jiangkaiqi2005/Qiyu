import 'dart:convert';

/// 与 DreamService 内部编码同构的测试夹具：构造 dream/state.md 文件
/// 内容（`# dream-state` 头 + schemaVersion 1 元数据标记）。新测试
/// 统一从这里取编码，不再各自复制 base64 细节；dream_test 既有
/// 三份复制为既有重复，不在本夹具收编范围。
String encodedDreamState({DateTime? lastSuccess, bool pending = false}) {
  final json = <String, Object?>{
    'schemaVersion': 1,
    if (lastSuccess != null)
      'lastSuccess': lastSuccess.toUtc().toIso8601String(),
    'pending': pending,
  };
  final encoded = base64Url
      .encode(utf8.encode(jsonEncode(json)))
      .replaceAll('=', '');
  return '# dream-state\n\n<!-- qiyu-dream-state:$encoded -->\n';
}
