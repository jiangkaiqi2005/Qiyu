abstract class PrivacyStrings {
  const PrivacyStrings();

  static PrivacyStrings of(bool english) =>
      english ? const PrivacyStringsEn() : const PrivacyStringsZh();

  String get title;
  String get heading;
  String get intro;
  String get localTag;
  String get localTitle;
  String get localBody;
  String get modelTag;
  String get modelTitle;
  String get modelBody;
  String get memoryTag;
  String get memoryTitle;
  String get memoryBody;
  String get diagnosticsTag;
  String get diagnosticsTitle;
  String get diagnosticsBody;
  String get backToSettings;
}

class PrivacyStringsZh extends PrivacyStrings {
  const PrivacyStringsZh();

  @override
  String get title => '隐私与边界';
  @override
  String get heading => '你的夜晚只属于你';
  @override
  String get intro => '栖语没有账号，没有云端记忆。这里说清楚数据在哪里、什么时候会用到你选择的模型服务，以及哪些内容永远不会被记住。';
  @override
  String get localTag => '本机';
  @override
  String get localTitle => '数据只保存在你自己的设备上';
  @override
  String get localBody =>
      '聊天记录、整理后的每日记录、长期印象、画像与关系、记忆控制，全部是保存在本机「栖语数据目录」里的 Markdown 文件，用任何文本编辑器都能直接打开查看。API Key 以明文保存在本机 provider.json 里，不落进记忆文件，也不会出现在备份里；请像保管密码一样保管这个文件，不要分享给别人。在设置里清除本机数据前会自动保留一份备份快照，随时可以在「备份与恢复」里找回；若你直接删除整个数据目录，则无法找回。';
  @override
  String get modelTag => '模型';
  @override
  String get modelTitle => '何时调用你选择的模型服务';
  @override
  String get modelBody =>
      '只有你在设置里配置了模型服务时，栖语才会联网，且只发往你填写的地址：你发来消息需要模型回应时、晚安后的当日整理、间隔至少七天的 Dream 深度整理、对话中的记忆查找，以及你主动发起的连接测试。没有配置模型服务时，一切都在本机规则里完成，不产生任何网络请求。涉及自伤等危机的倾诉会交给模型像朋友一样认真回应，并自然带出全国 24 小时心理援助热线 12356；未连接模型或模型没有回应时，本机兜底话术也会给出 12356。';
  @override
  String get memoryTag => '记忆';
  @override
  String get memoryTitle => '这些内容永远不会被提升为记忆';
  @override
  String get memoryBody =>
      'API Key、密码、口令、Cookie、验证码、身份证号、银行卡号、私钥等敏感原文，在写入任何记忆文件之前一律过滤。涉及私密内容的记忆在记忆中心默认打码展示，单次揭示需要明确确认，页面不缓存原文。';
  @override
  String get diagnosticsTag => '诊断';
  @override
  String get diagnosticsTitle => '日志与诊断统一脱敏';
  @override
  String get diagnosticsBody =>
      '本机日志和开发者诊断只记录请求来源、结果与错误类别，不记录任何对话正文；API Key、授权头、启动凭据和默认遮罩的敏感原文绝不会出现在任何导出里。开发者诊断默认关闭，只读，不触碰任何数据。';
  @override
  String get backToSettings => '返回设置';
}

class PrivacyStringsEn extends PrivacyStrings {
  const PrivacyStringsEn();

  @override
  String get title => 'Privacy & boundaries';
  @override
  String get heading => 'Your nights belong to you';
  @override
  String get intro =>
      'Qiyu has no account and no cloud memory. Here is where your data lives, when your chosen model service is used, and what is never kept as memory.';
  @override
  String get localTag => 'Local';
  @override
  String get localTitle => 'Your data stays on your device';
  @override
  String get localBody =>
      'Chats, daily notes, long term impressions, your profile and relationship, and memory controls are Markdown files in the local Qiyu data directory. You can open them in any text editor. Your API Key is stored in plain text in the local provider.json file. It is never put in memory files or backups. Treat this file like a password and do not share it. Before clearing local data in Settings, Qiyu saves a backup snapshot that you can restore from Backup & Restore. Deleting the entire data directory directly cannot be undone.';
  @override
  String get modelTag => 'Model';
  @override
  String get modelTitle => 'When your chosen model service is used';
  @override
  String get modelBody =>
      'Qiyu connects only after you configure a model service in Settings, and only to the address you provide: when a message needs a model reply, for daily memory after goodnight, for Dream after at least seven days, for memory lookup during chat, and when you run a connection test. Without a configured model, local rules handle replies. If you share thoughts of self harm, Qiyu asks the model to respond with care and include crisis help. If the model is unavailable, the English local fallback directs you to 988.';
  @override
  String get memoryTag => 'Memory';
  @override
  String get memoryTitle => 'What is never saved as memory';
  @override
  String get memoryBody =>
      'Raw API Keys, passwords, passcodes, Cookies, verification codes, identity numbers, bank card numbers, private keys, and other sensitive text are filtered before writing memory files. Private memories are masked by default in Memory Center. Revealing one requires confirmation, and the page does not cache the original text.';
  @override
  String get diagnosticsTag => 'Diagnostics';
  @override
  String get diagnosticsTitle => 'Logs and diagnostics are redacted';
  @override
  String get diagnosticsBody =>
      'Local logs and developer diagnostics record request sources, outcomes, and error categories, never chat text. API Keys, authorization headers, startup credentials, and masked sensitive text are excluded from exports. Developer diagnostics are off by default, read only, and do not change your data.';
  @override
  String get backToSettings => 'Back to Settings';
}
