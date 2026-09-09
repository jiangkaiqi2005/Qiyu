import 'package:qiyu_local_host/qiyu_local_host.dart';

/// 脚本化模型客户端：按 [completions] 顺序应答每次 complete 调用。
///
/// 超出脚本长度后默认重复最后一项（`repeatLastOnOverflow: false` 改为
/// 返回 null）；空脚本一律返回 null。每次调用的消息与 maxTokens 都
/// 留档在 [calls] / [maxTokens]，供用例断言提示词内容与预算参数。
final class ScriptedChatClient implements ProviderChatClient {
  ScriptedChatClient(this.completions, {this.repeatLastOnOverflow = true});

  final List<ModelCompletion?> completions;
  final bool repeatLastOnOverflow;
  final List<List<ModelMessage>> calls = [];
  final List<int?> maxTokens = [];

  @override
  Future<ModelCompletion?> complete(
    List<ModelMessage> messages, {
    int? maxTokens,
  }) async {
    calls.add(messages);
    this.maxTokens.add(maxTokens);
    if (completions.isEmpty) {
      return null;
    }
    final index = calls.length - 1;
    if (index < completions.length) {
      return completions[index];
    }
    return repeatLastOnOverflow ? completions.last : null;
  }
}
