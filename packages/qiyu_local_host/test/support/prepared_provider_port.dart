import 'package:qiyu_local_host/qiyu_local_host.dart';

/// 空闲补办轮询待办检测的 Provider 端假件：让待办检测照常进行、
/// 不发出任何模型流，与各节奏测试的原有假件同构。
final class PreparedProviderPort implements ProviderChatPort {
  const PreparedProviderPort();

  @override
  Future<PreparedProviderChatRequest?> prepareChatRequest() async =>
      PreparedProviderChatRequest(
        hardRulesAddendum: '',
        openStream: (messages, whenCancelled) async => null,
      );
}
