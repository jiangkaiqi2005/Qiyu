import 'dart:convert';
import 'dart:io';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

/// 秘密特征表 lockstep 守门（f16-B3）。
///
/// 两份秘密特征表是**有意不同**的集合，禁止合并：
/// - core `hidden_actions.dart` 的 `_secretPatterns`：模型输出提升为记忆
///   的闸门（隐藏动作的秘密判定），命中即丢弃整个动作；
/// - host `markdown_memory_repository.dart` 的 `_sessionRedactPatterns`：
///   会话与诊断落盘前的脱敏表，覆盖面更宽（另含 as_sk_/github_pat/
///   ghp/glp/xox/AKIA/AIza/JWT 等令牌特征与整行多项 Cookie 形态，
///   命中后替换为「[已脱敏]」占位）。
///
/// host 独有的整行多项 Cookie 形态在 core 由越权闸门覆盖：真实多项
/// Cookie 以分号串接，分号命中 core 的越权特征（命令分隔），动作先于
/// 秘密判定被整体丢弃，接受/拒绝结果一致，只是诊断码不同。
///
/// JSON 凭据另按解码后的键和值识别，由会话持久化与共享 Core 契约
/// 的公共回归覆盖；以下文本模式仍覆盖非结构化与不完整的片段。
/// 两份符号都是私有的，本测试沿用主链静态检查的手法直接读源码，把
/// 两侧的现行模式清单整块钉死：任一侧单边增删或改写模式，测试立即
/// 失败。改动一侧前，必须先评估另一侧是否同步。
void main() {
  final contract = jsonDecode(
    File('../../contracts/qiyu_behavior_contracts.json').readAsStringSync(),
  ) as Map<String, Object?>;
  for (final value
      in contract['credentialPlaceholderMatrix']! as List<Object?>) {
    final fixture = value! as Map<String, Object?>;
    final key = fixture['key']! as String;
    Map<String, String> forms(String text) => {
      'json': jsonEncode({key: text}),
      'escapedJson': '{"${fixture['escapedKey']}":${jsonEncode(text)}}',
      'colon': '$key: $text',
      'equals': '$key=$text',
      'fullWidthColon': '$key：$text',
    };
    final secrets = forms(fixture['secretValue']! as String);
    for (final form in forms('[已脱敏]').entries) {
      test('shared redaction matrix: $key/${form.key}', () {
        expect(redactSessionText(form.value), form.value);
        expect(redactSessionText(secrets[form.key]!), form.value);
        expect(
          redactSessionText('${form.value}\npassword: audit-only-other'),
          '${form.value}\npassword: [已脱敏]',
        );
      });
    }
  }

  group('秘密特征表 lockstep 守门', () {
    // 相对各自包根的源码路径；dart test 固定在包根目录运行。
    const coreSourcePath =
        '../../packages/qiyu_behavior_core/lib/src/hidden_actions.dart';
    const hostSourcePath = 'lib/src/markdown_memory_repository.dart';

    /// 从源码里截取 `[` 与第一个 `];` 之间的模式清单本体。
    String extractPatternBlock(String source, String startMarker) {
      final start = source.indexOf(startMarker);
      if (start < 0) {
        fail('找不到集合声明 $startMarker，模式清单可能已被改名或移动');
      }
      final end = source.indexOf('];', start);
      if (end < 0) {
        fail('集合声明 $startMarker 之后找不到清单结尾 ];');
      }
      return source.substring(start + startMarker.length, end);
    }

    String normalize(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

    test('core 秘密特征表（记忆提升闸门）钉死现行清单', () {
      final source = File(coreSourcePath).readAsStringSync();
      final block =
          extractPatternBlock(source, 'final _secretPatterns = [');
      expect(
        RegExp('RegExp\\(').allMatches(block).length,
        8,
        reason: 'core 秘密特征表的条目数变了：两份集合有意不同，'
            '改动一侧须评估另一侧是否同步',
      );
      expect(
        normalize(block),
        normalize(r'''
  RegExp(r'sk-[A-Za-z0-9_-]{16,}', caseSensitive: false),
  RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]{8,}', caseSensitive: false),
  RegExp(
    r'(?:' + _sensitiveKeyNames + r')\s*[:=：]\s*[^\s；;，,]+',
    caseSensitive: false,
  ),
  RegExp(
    r'("(?:' + _sensitiveKeyNames + r')"\s*:\s*")(?:[^"\\]|\\.)*',
    caseSensitive: false,
  ),
  RegExp(r'(?:验证码|otp|verification code)\s*[:=：]?\s*\d{4,8}', caseSensitive: false),
  RegExp(r'(?<!\d)\d{17}[\dXx](?!\d)'),
  RegExp(r'(?<!\d)(?:\d[ -]?){15,18}\d(?!\d)'),
  RegExp(
    r'-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?'
    r'-----END [A-Z0-9 ]*PRIVATE KEY-----',
    caseSensitive: false,
  ),
'''),
        reason: 'core 秘密特征表被改动：两份集合有意不同，'
            '改动一侧须评估另一侧是否同步',
      );
    });

    test('host 落盘脱敏表钉死现行清单', () {
      final source = File(hostSourcePath).readAsStringSync();
      final block =
          extractPatternBlock(source, 'final _sessionRedactPatterns = <RegExp>[');
      expect(
        RegExp('RegExp\\(').allMatches(block).length,
        21,
        reason: 'host 落盘脱敏表的条目数变了：两份集合有意不同，'
            '改动一侧须评估另一侧是否同步',
      );
      expect(
        normalize(block),
        normalize(r'''
  RegExp(r'as_sk_[A-Za-z0-9_-]{8,}', caseSensitive: false),
  RegExp(
    r'(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9_]{20,}(?![A-Za-z0-9_])',
    caseSensitive: false,
  ),
  RegExp(
    r'(?<![A-Za-z0-9_])ghp_[A-Za-z0-9]{20,}(?![A-Za-z0-9_])',
    caseSensitive: false,
  ),
  RegExp(
    r'(?<![A-Za-z0-9_-])glpat-[A-Za-z0-9_-]{10,}(?![A-Za-z0-9_-])',
    caseSensitive: false,
  ),
  RegExp(
    r'(?<![A-Za-z0-9-])xox[a-z]-[A-Za-z0-9-]{10,}(?![A-Za-z0-9-])',
    caseSensitive: false,
  ),
  RegExp(r'(?<![A-Z0-9])AKIA[A-Z0-9]{16}(?![A-Z0-9])'),
  RegExp(r'(?<![A-Za-z0-9_-])AIza[A-Za-z0-9_-]{20,}(?![A-Za-z0-9_-])'),
  RegExp(
    r'(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{5,}\.'
    r'[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{8,}(?![A-Za-z0-9_-])',
  ),
  RegExp(r'sk-[A-Za-z0-9_-]{16,}', caseSensitive: false),
  RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]{8,}', caseSensitive: false),
  RegExp(
    r'("(?:' + _sensitiveKeyNames + r')"\s*:\s*")(?:[^"\\]|\\.)*',
    caseSensitive: false,
  ),
  RegExp(
    r'("(?:set[- ])?cookie"\s*:\s*")'
    r'(?=(?:[^"\\]|\\.)*?[A-Za-z0-9_~-]+\s*=(?:[^\s；;，,"\\]|\\.))'
    r'(?:[^"\\]|\\.)*',
    caseSensitive: false,
  ),
  RegExp(
    r'((?:set[- ])?cookie\s*[:=：]\s*'
    r'(?=[^\r\n]*[A-Za-z0-9_~-]+\s*=[^\s；;，,]))[^\r\n]+',
    caseSensitive: false,
  ),
  RegExp(
    r'((?:set[- ])?cookie\s*[:=：]\s*)[A-Za-z0-9._~+/=-]{10,}',
    caseSensitive: false,
  ),
  RegExp(
    r'((?:' + _sensitiveKeyNames + r')\s*[:=：]\s*)[^\s；;，,]+',
    caseSensitive: false,
  ),
  RegExp(
    r'((?:验证码|otp|verification code)\s*[:=：]?\s*)\d{4,8}',
    caseSensitive: false,
  ),
  RegExp(r'((?:身份证(?:号)?|证件号)\s*[:=：]?\s*)\d{17}[\dXx]'),
  RegExp(r'((?:银行卡(?:号)?|卡号)\s*[:=：]?\s*)(?:\d[ -]?){15,18}\d'),
  RegExp(r'(?<!\d)\d{17}[\dXx](?!\d)'),
  RegExp(r'(?<!\d)(?:\d[ -]?){15,18}\d(?!\d)'),
  RegExp(
    r'-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?'
    r'-----END [A-Z0-9 ]*PRIVATE KEY-----',
    caseSensitive: false,
  ),
'''),
        reason: 'host 落盘脱敏表被改动：两份集合有意不同，'
            '改动一侧须评估另一侧是否同步',
      );
    });

    test('两侧清单保持有意差异：host 多覆盖的令牌特征不得反向并入 core', () {
      final coreSource = File(coreSourcePath).readAsStringSync();
      final coreBlock = extractPatternBlock(coreSource, 'final _secretPatterns = [');
      final hostSource = File(hostSourcePath).readAsStringSync();
      final hostBlock = extractPatternBlock(
        hostSource,
        'final _sessionRedactPatterns = <RegExp>[',
      );
      // host 落盘脱敏表独有、core 记忆闸门刻意不含的令牌特征前缀。
      for (final hostOnlyMarker in [
        'as_sk_',
        'github_pat_',
        'ghp_',
        'glpat-',
        'xox',
        'AKIA',
        'AIza',
        'eyJ',
      ]) {
        expect(hostBlock, contains(hostOnlyMarker), reason: hostOnlyMarker);
        expect(
          coreBlock,
          isNot(contains(hostOnlyMarker)),
          reason: 'core 秘密特征表不该出现落盘脱敏表独有的 $hostOnlyMarker：'
              '两份集合有意不同，改动一侧须评估另一侧是否同步',
        );
      }
    });
  });
}
