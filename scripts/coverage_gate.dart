// 覆盖率门禁：解析 lcov 报告，校验行覆盖率不低于既定水位。
// 用法：
//   dart run scripts/coverage_gate.dart --lcov <lcov.info> --min <百分比> [--label <名字>]
// 退出码：0 达标；1 低于水位；2 用法或报告本身有问题。
// 三个包的 lcov 路径分隔符不一（Windows 反斜杠、Linux 正斜杠），
// 只做统计不做路径断言，因此天然跨平台。
import 'dart:io';

void main(List<String> args) {
  final lcovPath = _stringArg(args, '--lcov');
  final minRaw = _stringArg(args, '--min');
  final label = _stringArg(args, '--label') ?? '覆盖率';
  if (lcovPath == null || minRaw == null) {
    stderr.writeln(
      '用法: dart run scripts/coverage_gate.dart '
      '--lcov <lcov.info> --min <百分比> [--label <名字>]',
    );
    exit(2);
  }
  final minPercent = double.tryParse(minRaw);
  if (minPercent == null) {
    stderr.writeln('水位不是合法数字: $minRaw');
    exit(2);
  }
  final report = File(lcovPath);
  if (!report.existsSync()) {
    stderr.writeln('找不到 lcov 报告: $lcovPath');
    exit(2);
  }

  var totalLines = 0;
  var hitLines = 0;
  final files = <_FileCoverage>[];
  String? currentPath;
  var currentTotal = 0;
  var currentHit = 0;
  for (final rawLine in report.readAsLinesSync()) {
    final line = rawLine.trim();
    if (line.startsWith('SF:')) {
      currentPath = line.substring(3);
      currentTotal = 0;
      currentHit = 0;
    } else if (line.startsWith('LF:')) {
      currentTotal = int.tryParse(line.substring(3)) ?? 0;
    } else if (line.startsWith('LH:')) {
      currentHit = int.tryParse(line.substring(3)) ?? 0;
    } else if (line == 'end_of_record') {
      if (currentPath != null && currentTotal > 0) {
        totalLines += currentTotal;
        hitLines += currentHit;
        files.add(_FileCoverage(currentPath, currentHit, currentTotal));
      }
      currentPath = null;
    }
  }
  if (totalLines == 0) {
    stderr.writeln('lcov 报告里没有可统计的行: $lcovPath');
    exit(2);
  }

  final percent = hitLines * 100 / totalLines;
  final verdict = percent >= minPercent ? '达标' : '不达标';
  stdout.writeln(
    '$label 行覆盖率 ${percent.toStringAsFixed(2)}% '
    '($hitLines/$totalLines)，水位 $minPercent%：$verdict',
  );
  if (percent >= minPercent) {
    return;
  }
  files.sort((a, b) {
    final byPercent = a.percent.compareTo(b.percent);
    if (byPercent != 0) return byPercent;
    return b.total.compareTo(a.total);
  });
  stdout.writeln('覆盖率最低的文件（补测试优先看这里）:');
  for (final entry in files.take(10)) {
    stdout.writeln(
      '  ${entry.percent.toStringAsFixed(1)}% (${entry.hit}/${entry.total})  '
      '${entry.path}',
    );
  }
  exit(1);
}

String? _stringArg(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) {
    return null;
  }
  return args[index + 1];
}

class _FileCoverage {
  _FileCoverage(this.path, this.hit, this.total);

  final String path;
  final int hit;
  final int total;

  double get percent => hit * 100 / total;
}
