import 'dart:convert';
import 'dart:io';

import 'package:qiyu_windows_host/qiyu_windows_host.dart';

void main(List<String> arguments) {
  final report = runHostPreflight(operatingSystem: Platform.operatingSystem);
  stdout.writeln(jsonEncode(report.toJson()));
  if (!report.ready) {
    exitCode = 1;
  }
}
