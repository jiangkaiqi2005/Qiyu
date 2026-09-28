import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import 'qiyu_strings.dart';

/// Read the shared language without changing route or widget identity.
/// Standalone widget tests without an app-level controller retain Chinese.
bool qiyuIsEn(BuildContext context) {
  try {
    return context.watch<LocaleController>().isEn;
  } on ProviderNotFoundException {
    return false;
  }
}

QiyuStrings qiyuStrings(BuildContext context) =>
    QiyuStrings.of(qiyuIsEn(context) ? 'en' : 'zh');

/// Event handlers and async callbacks must read without subscribing.
bool qiyuIsEnNow(BuildContext context) {
  try {
    return Provider.of<LocaleController>(context, listen: false).isEn;
  } on ProviderNotFoundException {
    return false;
  }
}

QiyuStrings qiyuStringsNow(BuildContext context) =>
    QiyuStrings.of(qiyuIsEnNow(context) ? 'en' : 'zh');
