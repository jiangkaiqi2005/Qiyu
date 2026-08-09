import 'package:flutter/foundation.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

final class MigrationBaselineViewModel extends ChangeNotifier {
  MigrationBaselineViewModel({QiyuBehaviorCore? behaviorCore})
    : _behaviorCore = behaviorCore ?? const QiyuBehaviorCore();

  final QiyuBehaviorCore _behaviorCore;

  bool get behaviorCoreConnected {
    final result = _behaviorCore.reply(
      const ChatRequest(requestId: 'flutter-preflight', text: '晚安'),
      StateSnapshot.initial('local-user'),
    );
    return result is ChatResult && result.messages.single == '晚安';
  }
}
