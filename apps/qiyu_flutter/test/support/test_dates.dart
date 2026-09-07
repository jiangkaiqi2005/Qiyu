/// 各测试文件共享的落盘日期键格式（sessions 与记忆清单用的 YYYY-MM-DD）。
String localDate(DateTime value) =>
    '${value.year}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
