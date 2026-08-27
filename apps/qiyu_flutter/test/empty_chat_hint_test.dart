import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view.dart';

void main() {
  // 边界即定档：05/11/13/18 整点切档，凌晨与清晨都归「今晚」。
  final cases = [
    (hour: 4, minute: 59, expected: '今晚想说点什么？'),
    (hour: 5, minute: 0, expected: '早上想说点什么？'),
    (hour: 8, minute: 30, expected: '早上想说点什么？'),
    (hour: 10, minute: 59, expected: '早上想说点什么？'),
    (hour: 11, minute: 0, expected: '中午想说点什么？'),
    (hour: 12, minute: 40, expected: '中午想说点什么？'),
    (hour: 13, minute: 0, expected: '下午想说点什么？'),
    (hour: 17, minute: 59, expected: '下午想说点什么？'),
    (hour: 18, minute: 0, expected: '今晚想说点什么？'),
    (hour: 23, minute: 5, expected: '今晚想说点什么？'),
    (hour: 0, minute: 15, expected: '今晚想说点什么？'),
  ];

  String hhmm(int hour, int minute) =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  for (final c in cases) {
    test('${hhmm(c.hour, c.minute)} → ${c.expected}', () {
      final hint = qiyuEmptyChatHint(DateTime(2026, 8, 27, c.hour, c.minute));
      expect(hint, c.expected);
    });
  }
}
