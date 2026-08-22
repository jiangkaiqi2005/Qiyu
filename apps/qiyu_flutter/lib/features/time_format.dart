/// 时间展示的统一出口：记忆中心、历史页与备份对话框共用同一套
/// 本地时间格式，避免各页面各自维护逐字重复的私有实现。
String twoDigits(int value) => value.toString().padLeft(2, '0');

String formatTime(DateTime value) {
  final local = value.toLocal();
  return '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)} '
      '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
}

/// 日期头部的用户语言：今天、昨天，其余落回「YYYY年M月D日」；
/// 解析不出的一律原样展示。
String formatDayHeader(String date) {
  final parsed = DateTime.tryParse(date);
  if (parsed == null) {
    return date;
  }
  final day = DateTime(parsed.year, parsed.month, parsed.day);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final difference = today.difference(day).inDays;
  if (difference == 0) {
    return '今天';
  }
  if (difference == 1) {
    return '昨天';
  }
  return '${parsed.year}年${parsed.month}月${parsed.day}日';
}
