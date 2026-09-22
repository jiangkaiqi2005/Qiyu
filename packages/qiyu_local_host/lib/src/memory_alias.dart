import 'dart:convert';

import 'memory_text_primitives.dart';
import 'model_gateway.dart';
import 'provider_settings_service.dart';

/// 控制范围关联扩展（裁定票 03）：ban / freeze / delete 发生时，用一次
/// 有界模型调用找出同一语义记忆的其它说法，作为别名并入控制条目——
/// 文字包含匹配认不出「换工作」与「跳槽」是同一件事，别名让控制清单
/// 覆盖用户可能的其它指代。方向沿用既有「宁多勿漏」口径：多纳入的
/// 别名只可能多屏蔽同一语义的内容，绝不会放开任何控制；用户用任何
/// 一个说法重提，控制都仍然生效。
///
/// 别名是增强不是门槛：Provider 未配置（complete 返回 null）、调用
/// 失败、输出为空或越界，一律静默退回无别名，控制本身照常成功。
/// 调用走 Provider 层既有的 [ProviderChatClient]（与 Dream、日终理解
/// 同一模式），不散入 UI 或 Chat Service。

/// 单条控制的别名条数上限：控制扩展仍要有界——无界扩展会让一次误判
/// 放大成整库屏蔽，5 条同义/相关表述已覆盖常见指代。
const maxMemoryAliasesPerControl = 5;

/// 单条别名的长度上限（runes）：别名要短才可能作为包含匹配的前缀
/// 命中更长的派生句；长别名几乎不可能被包含匹配命中，只会拖慢每次
/// 过滤。取控制摘要限长（60 runes）的一半。
const maxMemoryAliasRunes = 30;

/// 别名调用的输出预算：只够一个短 JSON 数组，无需聊天级预算。
const _memoryAliasMaxTokens = 200;

const _memoryAliasSystemPrompt =
    '你是栖语的记忆控制助手。用户要求对一条记忆实施控制（不再提起、'
    '暂停使用或删除）。列出用户在对话里可能用来指代同一件事的其它'
    '说法：同义表述、俗称、相关指代都可以，宁多勿漏；与这件事无关的'
    '不要列。只输出 JSON 数组，元素是简短表述，不要任何解释。';

/// 一次有界别名扩展调用。任何失败路径都返回空列表（静默退回无别名）。
Future<List<String>> expandMemoryAliases(
  ProviderChatClient? client,
  String summary,
) async {
  if (client == null || normalizeMemoryText(summary).isEmpty) {
    return const [];
  }
  try {
    final completion = await client.complete([
      const ModelMessage(ModelMessageRole.system, _memoryAliasSystemPrompt),
      ModelMessage(ModelMessageRole.user, '记忆摘要：$summary'),
    ], maxTokens: _memoryAliasMaxTokens);
    // Provider 未配置（completion 为 null）或调用失败（text 为 null）：
    // 控制照常，退回无别名。
    final raw = completion?.text;
    if (raw == null) {
      return const [];
    }
    return sanitizeMemoryAliases(_parseAliasArray(raw), summary);
  } on Object {
    return const [];
  }
}

/// 解析模型输出的别名数组：只认 JSON 字符串数组，其余形态（对象、
/// 标量、截断的 JSON）一律按空处理——调用本身已经成功，形态不符
/// 只当没有别名。
List<String> _parseAliasArray(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List<Object?>) {
      return const [];
    }
    return decoded.whereType<String>().toList();
  } on FormatException {
    return const [];
  }
}

/// 别名清洗（上限在此执行）：形态清洗（换行与竖线会破坏控制条目的
/// 单行格式，折成空格）、限长、去重、去掉与主摘要等价的项，最后按
/// 条数上限截断。输入可能来自模型输出，只做形状约束——别名不进任何
/// 提示词或界面（界面只见到条数）。
List<String> sanitizeMemoryAliases(List<String> raw, String summary) {
  final seen = <String>{normalizeMemoryText(summary)};
  final aliases = <String>[];
  for (final candidate in raw) {
    final cleaned = candidate
        .replaceAll(RegExp(r'[\r\n|]'), ' ')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
    if (cleaned.isEmpty || cleaned.runes.length > maxMemoryAliasRunes) {
      continue;
    }
    if (!seen.add(normalizeMemoryText(cleaned))) {
      continue;
    }
    aliases.add(cleaned);
    if (aliases.length >= maxMemoryAliasesPerControl) {
      break;
    }
  }
  return List.unmodifiable(aliases);
}
